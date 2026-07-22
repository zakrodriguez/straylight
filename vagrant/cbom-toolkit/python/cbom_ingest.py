#!/usr/bin/env python3
"""Ingest CycloneDX CBOM components into OpenSearch as structured events.

Usage:
    python3 cbom_ingest.py cbom-deduped.json --scanner cbomkit-theia
    python3 cbom_ingest.py cbom.json --scanner cbom-lens --dry-run
    python3 cbom_ingest.py cbom.json --scanner cbomkit-theia --json
    python3 cbom_ingest.py cbom.json --scanner cbomkit-theia --event-type diff-added
"""
import json
import os
import ssl
import sys
import re
import time
import uuid
import hashlib
import argparse
import base64
import urllib.request
import urllib.error
from datetime import datetime, timezone


# ── Versioned envelope contract ─────────────────────────────────────────────
# The cbom_* / cf_* / adcs_* field vocabulary + producer registry live in ONE
# place: cbom-toolkit/schema/cbom_envelope.json. The OpenSearch index mapping
# is generated from the same file (gen_opensearch_mapping.py), so a new field
# or producer is a single-file edit instead of four hand-synced copies.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SCHEMA_PATH = os.environ.get(
    'CBOM_ENVELOPE_SCHEMA',
    os.path.join(_HERE, '..', 'schema', 'cbom_envelope.json'),
)


def _load_envelope(path=_SCHEMA_PATH):
    """Load the envelope contract. Tolerates a missing file (e.g. when only the
    Python slice is staged on scanner1) by falling back to built-in defaults so
    ingest never hard-fails on a packaging gap."""
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {
            'envelope_version': 'cbom-envelope/v1',
            'producers': {
                'cyclonedx': {'match_schema_prefixes': [], 'default': True},
                'cloudflare_pqc/v1': {'match_schema_prefixes': ['cloudflare_pqc/']},
                'adcs_pqc_audit/v1': {'match_schema_prefixes': ['adcs_pqc_audit/']},
            },
        }


ENVELOPE = _load_envelope()
ENVELOPE_VERSION = ENVELOPE.get('envelope_version', 'cbom-envelope/v1')


def select_producer(bom):
    """Return (producer_id, schema_value) for a parsed report.

    Replaces the old `schema.startswith('cloudflare_pqc/')` sniffing with an
    explicit registry lookup keyed on the report's `schema` field. Unknown or
    absent schemas fall back to the producer flagged default=True (CycloneDX).
    """
    schema_val = ''
    if isinstance(bom, dict):
        schema_val = bom.get('schema', '') or ''
    producers = ENVELOPE.get('producers', {})
    for pid, spec in producers.items():
        for prefix in spec.get('match_schema_prefixes', []):
            if schema_val.startswith(prefix):
                return pid, schema_val
    for pid, spec in producers.items():
        if spec.get('default'):
            return pid, schema_val
    return 'cyclonedx', schema_val


def _build_opener(base_url, username=None, password=None, ca_cert=None, insecure=False):
    """Build a urllib opener that supports HTTPS + HTTP Basic Auth.

    OpenSearch is fronted by observe_tls nginx on :9244 (TLS + Basic Auth).
    Set --username/--password (or OPENSEARCH_USER / OPENSEARCH_PASS env vars)
    to authenticate. Use --ca-cert to verify the step-ca-issued cert chain,
    or --insecure to skip verification (lab use only).
    """
    handlers = []
    if base_url.lower().startswith('https://'):
        ctx = ssl.create_default_context(cafile=ca_cert) if ca_cert else ssl.create_default_context()
        if insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener(*handlers) if handlers else urllib.request.build_opener()


# Classifier lives in pqc_classify so cbom_score.py and cbom_ingest.py
# can't drift apart again (bug #14 in pqc-remediation-progress).
from pqc_classify import classify as get_pqc_status  # noqa: E402


def get_location(component):
    for occ in component.get('evidence', {}).get('occurrences', []):
        loc = occ.get('location')
        if loc:
            return loc
    return '?'


def get_vm_name(location):
    if location == '?':
        return '?'
    m = re.match(r'^([^/]+)/', location)
    return m.group(1) if m else '?'


def parse_iso8601(s):
    """Parse ISO 8601 datetime string to timezone-aware datetime.

    Handles trailing 'Z' and timezone offsets like +00:00.
    Returns None if parsing fails.
    """
    if not s:
        return None
    try:
        s = s.replace('Z', '+00:00')
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def build_bom_ref_index(bom):
    """Build lookup from bom-ref UUID to component."""
    return {c['bom-ref']: c for c in bom.get('components', []) if 'bom-ref' in c}


def get_cert_pqc_status(cert_props, ref_index):
    """Classify a certificate's PQC status by resolving its signature algorithm ref.

    Certificates themselves don't have algorithm names — they reference
    algorithm and key components via signatureAlgorithmRef / subjectPublicKeyRef.
    We resolve the ref and classify based on the actual algorithm name.
    """
    sig_ref = cert_props.get('signatureAlgorithmRef')
    if sig_ref and sig_ref in ref_index:
        sig_name = ref_index[sig_ref].get('name', '')
        return get_pqc_status(sig_name)
    return 'unknown'


def build_documents(bom, scanner, event_type='scan'):
    scan_time = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    ref_index = build_bom_ref_index(bom)
    documents = []

    for c in bom.get('components', []):
        cp = c.get('cryptoProperties', {})
        asset_type = cp.get('assetType')
        name = c.get('name', '?')
        # A component can carry multiple occurrences after dedup (same algo
        # served at multiple endpoints). Emit one doc per occurrence so each
        # location is independently filterable in dashboards.
        occurrences = c.get('evidence', {}).get('occurrences', []) or [{}]
        for occ in occurrences:
            location = occ.get('location') or get_location(c)
            vm_name = get_vm_name(location)
            documents.append(_build_one_doc(c, cp, asset_type, name, location, vm_name, scanner, scan_time, event_type, ref_index))
    return documents


def _build_one_doc(c, cp, asset_type, name, location, vm_name, scanner, scan_time, event_type, ref_index):

        # Discrete bool field for dashboard filters: pqc_handshake_probe
        # stamps "[PQC-ONLY]" prefix on every component from a pure-PQC
        # endpoint (cert + sig algo + pubkey) so legacy clients can't reach
        # it. Surfacing this as a separate field beats fragile name-string
        # matching in OSD visualizations.
        is_pqc_only = name.startswith('[PQC-ONLY]')

        doc = {
            '@timestamp': scan_time,
            'message': f"[{scanner}] {asset_type}: {name}",
            'cbom_envelope_version': ENVELOPE_VERSION,
            'cbom_schema': 'cyclonedx',
            'cbom_scanner': scanner,
            'cbom_scan_time': scan_time,
            'cbom_asset_type': asset_type,
            'cbom_vm': vm_name,
            'cbom_name': name,
            'cbom_location': location,
            'cbom_bom_ref': c.get('bom-ref'),
            'cbom_event_type': event_type,
            'cbom_pqc_only': is_pqc_only,
        }

        if asset_type == 'algorithm':
            ap = cp.get('algorithmProperties', {})
            doc['cbom_algorithm'] = name
            doc['cbom_primitive'] = ap.get('primitive')
            doc['cbom_pqc_status'] = get_pqc_status(name)

        elif asset_type == 'certificate':
            cert_p = cp.get('certificateProperties', {})
            subject = cert_p.get('subjectName')
            issuer = cert_p.get('issuerName')
            not_after = cert_p.get('notValidAfter')
            doc['cbom_subject'] = subject
            doc['cbom_issuer'] = issuer
            # Normalize dates for OpenSearch date mapping
            nb_dt = parse_iso8601(cert_p.get('notValidBefore'))
            na_dt = parse_iso8601(not_after)
            doc['cbom_not_before'] = nb_dt.strftime('%Y-%m-%dT%H:%M:%SZ') if nb_dt else None
            doc['cbom_not_after'] = na_dt.strftime('%Y-%m-%dT%H:%M:%SZ') if na_dt else None

            # Resolve signature algorithm for PQC classification
            doc['cbom_pqc_status'] = get_cert_pqc_status(cert_p, ref_index)

            # Also store the resolved signature algorithm name
            sig_ref = cert_p.get('signatureAlgorithmRef')
            if sig_ref and sig_ref in ref_index:
                doc['cbom_sig_algorithm'] = ref_index[sig_ref].get('name')

            # Days until certificate expiry (negative = already expired)
            not_after_dt = parse_iso8601(not_after)
            if not_after_dt is not None:
                delta = not_after_dt - datetime.now(timezone.utc)
                doc['cbom_days_to_expiry'] = delta.days

            # Self-signed detection
            if subject and issuer:
                doc['cbom_is_root'] = (subject == issuer)

        elif asset_type == 'related-crypto-material':
            rp = cp.get('relatedCryptoMaterialProperties', {})
            doc['cbom_key_type'] = rp.get('type')
            doc['cbom_key_size'] = rp.get('size')
            doc['cbom_pqc_status'] = get_pqc_status(name)

        else:
            doc['cbom_pqc_status'] = get_pqc_status(name)

        return doc


def documents_from_cloudflare_pqc(doc, source_file):
    """Flatten a cloudflare_pqc/v1 report into per-probe OpenSearch documents."""
    # Fall back to "now" when run_at is missing, mirroring build_documents
    # above. Time-filtered dashboards pin to @timestamp so this field MUST
    # be present and parseable.
    run_at = doc.get('run_at') or time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    scanner = doc.get('scanner', 'scanner1')
    out = []
    for probe in doc.get('probes', []):
        endpoint = probe.get('endpoint')
        stack = probe.get('stack')
        d = {
            # @timestamp + cbom_scan_time mirror the CycloneDX path
            # (build_documents above) so CF docs land on the same
            # time-filtered dashboards. cbom_scan_time / cbom_bom_ref /
            # cbom_location also feed the deterministic _id in
            # send_to_opensearch — without them every probe in every run
            # collapses to the same _id and overwrites itself.
            '@timestamp': run_at,
            'cbom_envelope_version': ENVELOPE_VERSION,
            'cbom_schema': 'cloudflare_pqc/v1',
            'cbom_scan_time': run_at,
            'cbom_bom_ref': f'cf:{endpoint}:{stack}',
            'cbom_location': endpoint,
            'cbom_scanner': f'{scanner}-cloudflare',
            'cbom_source': 'cloudflare-pqc',
            'cbom_source_file': source_file,
            'cf_endpoint': endpoint,
            'cf_endpoint_name': probe.get('endpoint_name'),
            'cf_stack': stack,
            # Bare .get() (no default) so missing → None → OpenSearch omits
            # the field. Distinguishes malformed probes from real failures.
            'cf_success': probe.get('success'),
            'cf_tls_version': probe.get('tls_version'),
            'cf_cipher': probe.get('cipher'),
            'cf_kex_offered': probe.get('kex_group_offered'),
            'cf_handshake_ms': probe.get('handshake_ms'),
            'cf_cert_fp_sha256': probe.get('server_cert_fingerprint_sha256'),
            'cf_cert_issuer': probe.get('server_cert_issuer'),
            'cf_error': probe.get('error'),
        }
        # Map to the existing cbom_pqc_status field used by the dashboard's
        # stacked-bar-by-scanner panel. CF-source docs introduce three
        # values not produced by pqc_classify.classify():
        #   - 'pqc-hybrid' (TLS 1.3 with X25519MLKEM768 KEX group)
        #   - 'classical' (successful handshake, no PQC KEX)
        #   - 'failed'    (probe failed: connect/handshake error)
        # When success is None (key absent / malformed probe) we leave the
        # field unset rather than misclassify a missing measurement as a
        # real failure.
        success = probe.get('success')
        if success and probe.get('kex_group_offered') == 'X25519MLKEM768':
            d['cbom_pqc_status'] = 'pqc-hybrid'
        elif success is True:
            d['cbom_pqc_status'] = 'classical'
        elif success is False:
            d['cbom_pqc_status'] = 'failed'
        # else: success is None → don't set cbom_pqc_status at all
        out.append(d)
    return out


def documents_from_adcs_pqc_audit(doc, source_file):
    """Flatten an adcs_pqc_audit/v1 report into per-layer OpenSearch documents.

    Invoke-PqcAudit.ps1 writes a JSON sidecar next to its text report; each
    'layer' (CNG primitives / CertEnroll / AD CS issuance / Schannel) becomes
    one doc so the OSD `AD CS PQC Gap` panel can render layer-by-layer status
    over time. Previously this audit was a text-file dead-end never ingested.
    cbom_pqc_status is derived from the layer verdict so the audit
    rolls up into the same cross-protocol posture panels as everything else.
    """
    run_at = doc.get('run_at') or time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    host = doc.get('host') or '?'
    build = doc.get('build')
    scanner = doc.get('scanner') or f'{host}-adcs-audit'
    out = []
    for layer in doc.get('layers', []):
        layer_id = layer.get('id')
        status = (layer.get('status') or '').upper().replace(' ', '_')
        available = status == 'AVAILABLE'
        d = {
            '@timestamp': run_at,
            'cbom_envelope_version': ENVELOPE_VERSION,
            'cbom_schema': 'adcs_pqc_audit/v1',
            'cbom_scan_time': run_at,
            # _id components: distinct per host + layer + run so re-runs upsert
            # but successive audits preserve the time series.
            'cbom_bom_ref': f'adcs:{host}:{layer_id}',
            'cbom_location': host,
            'cbom_vm': host,
            'cbom_scanner': scanner,
            'cbom_source': 'adcs-pqc-audit',
            'cbom_source_file': source_file,
            'cbom_event_type': 'audit',
            'message': f"[{scanner}] {layer_id}: {status}",
            'adcs_layer': layer_id,
            'adcs_layer_name': layer.get('name'),
            'adcs_status': status,
            'adcs_build': build,
            'adcs_detail': layer.get('detail'),
            # PQC posture rollup: an AVAILABLE PQC layer is quantum-safe, a
            # NOT_AVAILABLE one is a known gap (quantum-vulnerable today).
            'cbom_pqc_status': 'quantum-safe' if available else 'quantum-vulnerable',
        }
        out.append(d)
    return out


def compute_doc_id(doc):
    """Deterministic _id so re-ingesting the same record upserts instead of
    appending a duplicate.

    Base key = scan_time | bom_ref | location:
      - scan_time   distinguishes successive scans (preserves time series)
      - bom_ref     distinguishes components within one scan
      - location    distinguishes occurrences at multiple endpoints

    Timestamp-collision hardening: on a coarse or missing timestamp (e.g. date-only, or no
    scan_time at all) that base key can collapse genuinely distinct scans onto
    the same _id, silently overwriting earlier data. When the timestamp lacks
    sub-second / second resolution we mix in a stable content hash of the rest
    of the document so two different records taken in the same coarse window
    get distinct ids while an identical re-ingest of the SAME record still
    upserts (the hash is over content, not a random salt).
    """
    scan_time = str(doc.get('cbom_scan_time', '') or '')
    bom_ref = str(doc.get('cbom_bom_ref', '') or '')
    location = str(doc.get('cbom_location', '') or '')
    base = f"{scan_time}|{bom_ref}|{location}"

    # A timestamp with explicit seconds (…THH:MM:SS…) is fine-grained enough on
    # its own; anything coarser (date-only) or missing is "coarse".
    fine_grained = bool(re.search(r'T\d{2}:\d{2}:\d{2}', scan_time))
    if not fine_grained:
        payload = json.dumps(doc, sort_keys=True, default=str)
        content_hash = hashlib.sha256(payload.encode('utf-8')).hexdigest()[:16]
        base = f"{base}|{content_hash}"

    return str(uuid.uuid5(uuid.NAMESPACE_URL, base))


def send_to_opensearch(documents, base_url, index='cbom', batch_size=500,
                       username=None, password=None, ca_cert=None, insecure=False):
    """Send documents to OpenSearch via _bulk API."""
    url = f"{base_url.rstrip('/')}/{index}/_bulk"
    opener = _build_opener(base_url, username=username, password=password,
                           ca_cert=ca_cert, insecure=insecure)
    auth_header = None
    if username and password:
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        auth_header = f"Basic {token}"
    sent = 0
    errors = 0
    for i in range(0, len(documents), batch_size):
        batch = documents[i:i + batch_size]
        lines = []
        for doc in batch:
            doc_id = compute_doc_id(doc)
            lines.append(json.dumps({"index": {"_id": doc_id}}))
            lines.append(json.dumps(doc))
        body = '\n'.join(lines) + '\n'
        data = body.encode('utf-8')
        headers = {'Content-Type': 'application/x-ndjson'}
        if auth_header:
            headers['Authorization'] = auth_header
        req = urllib.request.Request(url, data=data, headers=headers)
        try:
            resp = opener.open(req)
            result = json.loads(resp.read())
            batch_errors = 0
            if result.get('errors'):
                for item in result.get('items', []):
                    if 'error' in item.get('index', {}):
                        batch_errors += 1
                        if errors + batch_errors <= 3:
                            print(f"  \033[33mWARN\033[0m Bulk error: {item['index']['error']}", file=sys.stderr)
            sent += len(batch) - batch_errors
            errors += batch_errors
        except urllib.error.URLError as e:
            errors += len(batch)
            if errors <= 3:
                print(f"  \033[33mWARN\033[0m Failed to send batch: {e}", file=sys.stderr)
    return sent, errors


def main():
    parser = argparse.ArgumentParser(description="Ingest CBOM into OpenSearch as structured events")
    parser.add_argument("input", help="CBOM JSON file")
    parser.add_argument("--scanner", default="unknown", help="Scanner name (e.g. cbomkit-theia)")
    parser.add_argument("--opensearch-url",
                        default=os.environ.get("OPENSEARCH_URL", "https://192.168.56.53:9244"),
                        help="OpenSearch base URL (now TLS-fronted on :9244; see observe_tls role)")
    parser.add_argument("--username", default=os.environ.get("OPENSEARCH_USER", "beats"),
                        help="HTTP Basic Auth user (default: beats, or $OPENSEARCH_USER)")
    parser.add_argument("--password", default=os.environ.get("OPENSEARCH_PASS"),
                        help="HTTP Basic Auth password (default: $OPENSEARCH_PASS; required for https://)")
    parser.add_argument("--ca-cert", default=os.environ.get("OPENSEARCH_CA"),
                        help="Path to PEM CA bundle for TLS verification (default: $OPENSEARCH_CA)")
    parser.add_argument("--insecure", action="store_true",
                        help="Skip TLS verification (lab-only; use --ca-cert in production)")
    parser.add_argument("--event-type", default="scan",
                        help="Event type label (e.g. scan, diff-added, diff-removed)")
    parser.add_argument("--dry-run", action="store_true", help="Print documents instead of sending")
    parser.add_argument("--json", action="store_true", help="Output as JSON array")
    args = parser.parse_args()

    with open(args.input) as f:
        bom = json.load(f)

    # Dispatch via the versioned producer registry instead of
    # ad-hoc startswith() sniffing. The report's `schema` field selects the
    # producer; unknown/absent schemas fall back to CycloneDX (default=True).
    producer_id, _schema_val = select_producer(bom)
    if producer_id == 'cloudflare_pqc/v1':
        documents = documents_from_cloudflare_pqc(bom, source_file=args.input)
    elif producer_id == 'adcs_pqc_audit/v1':
        documents = documents_from_adcs_pqc_audit(bom, source_file=args.input)
    else:
        documents = build_documents(bom, args.scanner, args.event_type)

    if args.json:
        print(json.dumps(documents, indent=2))
        sys.exit(0)

    if args.dry_run:
        for doc in documents:
            print(json.dumps(doc))
        print(f"\n  DryRun: {len(documents)} documents generated (not sent)")
        sys.exit(0)

    sent, errors = send_to_opensearch(
        documents, args.opensearch_url,
        username=args.username, password=args.password,
        ca_cert=args.ca_cert, insecure=args.insecure,
    )
    print(f"  \033[32mSent: {sent} / {len(documents)} documents to {args.opensearch_url}/cbom/_bulk\033[0m")
    if errors:
        print(f"  \033[31mErrors: {errors}\033[0m")

    sys.exit(1 if errors > 0 else 0)


if __name__ == '__main__':
    main()
