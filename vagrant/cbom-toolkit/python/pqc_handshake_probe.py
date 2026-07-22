#!/usr/bin/env python3
"""Probe TLS endpoints with OpenSSL 3.5 to detect PQC certificates.

The lab's nmap-network scanner uses scanner1's system OpenSSL (3.0), which
cannot handshake with pure-PQC certs (ML-DSA-65 leafs). Such endpoints are
intentionally invisible to nmap — that's the demo point. This scanner uses
the OpenSSL 3.5 binary (`/opt/openssl-3.5/bin/openssl`) to:

1. Attempt a TLS handshake with each target.
2. Capture the leaf certificate when the handshake succeeds.
3. Parse subject / issuer / signature algorithm / public key algorithm.
4. Emit CycloneDX 1.6 CBOM components (certificate + sig algo + pk algo).
5. Tag endpoints where system openssl ALSO fails — these are "pqc-only".

Designed to run on scanner1 where /opt/openssl-3.5/bin/openssl exists.
Run with `--targets host:port,host:port` or `--targets-file path`.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import uuid

OPENSSL35 = os.environ.get('OPENSSL35_BIN', '/opt/openssl-3.5/bin/openssl')
OPENSSL_SYS = os.environ.get('OPENSSL_SYS_BIN', 'openssl')

# Algorithm classifiers — must match cbom_score.py conventions.
PQC_SIG_ALGOS = {
    'ML-DSA-44', 'ML-DSA-65', 'ML-DSA-87',
    'SLH-DSA-SHA2-128s', 'SLH-DSA-SHA2-256s',
}
PQC_PK_ALGOS = PQC_SIG_ALGOS  # ML-DSA cert pubkey == ML-DSA sig algo


def run(cmd, timeout=8, stdin=None):
    """Run a subprocess; return (rc, stdout, stderr) — never raises."""
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            input=stdin if stdin is not None else '',
        )
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, '', 'timeout'
    except FileNotFoundError as e:
        return 127, '', str(e)


def fetch_leaf_cert(openssl_bin, host, port, timeout=8):
    """Run `openssl s_client | openssl x509 -text` and return the parsed text.

    Returns (success: bool, x509_text: str, raw_handshake: str).
    """
    sclient_cmd = [
        openssl_bin, 's_client', '-connect', f'{host}:{port}',
        '-servername', host, '-showcerts',
    ]
    rc, out, err = run(sclient_cmd, timeout=timeout, stdin='')
    if rc != 0 and 'CERTIFICATE' not in out:
        return False, '', err or out
    # Pipe just the first cert into x509 -text
    cert_match = re.search(
        r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
        out, re.DOTALL,
    )
    if not cert_match:
        return False, '', 'no certificate in s_client output'
    rc2, x509_text, err2 = run(
        [openssl_bin, 'x509', '-noout', '-text'],
        timeout=5, stdin=cert_match.group(0),
    )
    if rc2 != 0:
        return False, '', err2
    return True, x509_text, out


def parse_cert(x509_text):
    """Extract subject, issuer, sig algo, pk algo from `openssl x509 -text`."""
    fields = {}
    m = re.search(r'Subject:\s*(.+)', x509_text)
    fields['subject'] = m.group(1).strip() if m else ''
    m = re.search(r'Issuer:\s*(.+)', x509_text)
    fields['issuer'] = m.group(1).strip() if m else ''
    # Signature algos appear twice in cert text; take the first (TBSCert sig).
    m = re.search(r'Signature Algorithm:\s*(\S+)', x509_text)
    fields['sig_algo'] = m.group(1).strip() if m else ''
    m = re.search(r'Public Key Algorithm:\s*(\S+)', x509_text)
    fields['pk_algo'] = m.group(1).strip() if m else ''
    m = re.search(r'Not Before\s*:\s*(.+)', x509_text)
    fields['not_before'] = m.group(1).strip() if m else ''
    m = re.search(r'Not After\s*:\s*(.+)', x509_text)
    fields['not_after'] = m.group(1).strip() if m else ''
    return fields


def to_iso8601(rfc_date):
    """Convert openssl's 'May 10 23:35:10 2026 GMT' to ISO 8601, or ''."""
    if not rfc_date:
        return ''
    try:
        dt = datetime.datetime.strptime(rfc_date, '%b %d %H:%M:%S %Y %Z')
        return dt.replace(tzinfo=datetime.timezone.utc).isoformat()
    except ValueError:
        return ''


def probe_target(host, port, timeout=8):
    """Attempt handshakes with both openssl 3.5 and system openssl.

    Returns dict with handshake outcomes and parsed cert (if any).
    """
    pqc_ok, pqc_text, _ = fetch_leaf_cert(OPENSSL35, host, port, timeout)
    sys_ok, _, _ = fetch_leaf_cert(OPENSSL_SYS, host, port, timeout)
    return {
        'host': host,
        'port': int(port),
        'pqc_handshake_ok': pqc_ok,
        'sys_handshake_ok': sys_ok,
        'pqc_only': pqc_ok and not sys_ok,
        'cert': parse_cert(pqc_text) if pqc_ok else None,
    }


def is_quantum_safe_sig(algo):
    return algo in PQC_SIG_ALGOS


def to_cbom(probes):
    """Convert probe results to CycloneDX 1.6 CBOM."""
    components = []
    for p in probes:
        if not p['cert']:
            continue
        host, port = p['host'], p['port']
        cert = p['cert']
        # Match nmap_to_cbom convention: "vm/ip:port" so cbom_score.py groups by VM
        location = f'{host}/{host}:{port}'

        # PQC-ONLY tag: stamp on every component from this endpoint so
        # cbom_ingest can derive the cbom_pqc_only boolean for dashboards.
        # Without this, only the cert had the tag in its name.
        tag = '[PQC-ONLY] ' if p['pqc_only'] else ''

        # signature algorithm component
        sig_algo = cert.get('sig_algo') or 'unknown'
        sig_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:sig:{sig_algo}'))
        sig_component = {
            'bom-ref': sig_ref,
            'type': 'cryptographic-asset',
            'name': f'{tag}{sig_algo}',
            'evidence': {'occurrences': [{'location': location}]},
            'cryptoProperties': {
                'assetType': 'algorithm',
                'algorithmProperties': {
                    'primitive': 'signature',
                    'cryptoFunctions': ['sign'],
                },
            },
        }
        components.append(sig_component)

        # public key component
        pk_algo = cert.get('pk_algo') or sig_algo
        pk_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:pk:{pk_algo}'))
        components.append({
            'bom-ref': pk_ref,
            'type': 'cryptographic-asset',
            'name': f'{tag}{pk_algo}',
            'evidence': {'occurrences': [{'location': location}]},
            'cryptoProperties': {
                'assetType': 'related-crypto-material',
                'relatedCryptoMaterialProperties': {
                    'type': 'public-key',
                },
            },
        })

        # certificate component
        cert_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:cert:{cert.get("subject","")}'))
        cert_props = {
            'subjectName': cert.get('subject', ''),
            'issuerName': cert.get('issuer', ''),
            'certificateFormat': 'X.509',
            'signatureAlgorithmRef': sig_ref,
            'subjectPublicKeyRef': pk_ref,
        }
        nb = to_iso8601(cert.get('not_before'))
        na = to_iso8601(cert.get('not_after'))
        if nb:
            cert_props['notValidBefore'] = nb
        if na:
            cert_props['notValidAfter'] = na

        leaf_label = cert.get('subject', '') or 'unknown'
        if p['pqc_only']:
            leaf_label = f'[PQC-ONLY] {leaf_label}'

        components.append({
            'bom-ref': cert_ref,
            'type': 'cryptographic-asset',
            'name': f'{leaf_label} (signed with {sig_algo})',
            'evidence': {'occurrences': [{'location': location}]},
            'cryptoProperties': {
                'assetType': 'certificate',
                'certificateProperties': cert_props,
            },
        })

    serial = 'urn:uuid:' + str(uuid.uuid4())
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    return {
        '$schema': 'https://cyclonedx.org/schema/bom-1.6.schema.json',
        'bomFormat': 'CycloneDX',
        'specVersion': '1.6',
        'serialNumber': serial,
        'version': 1,
        'metadata': {
            'timestamp': timestamp,
            'component': {
                'type': 'application',
                'name': 'pqc-handshake-probe',
                'version': '1.0.0',
            },
        },
        'components': components,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        '--targets', required=True,
        help='Comma-separated host:port pairs, e.g. 192.168.56.53:8443,192.168.56.53:8444',
    )
    ap.add_argument('-o', '--output', default='-', help='Output CBOM path (- for stdout)')
    ap.add_argument('--timeout', type=int, default=8, help='Per-handshake timeout (s)')
    ap.add_argument('--summary', action='store_true', help='Also print human summary to stderr')
    args = ap.parse_args()

    targets = [t.strip() for t in args.targets.split(',') if t.strip()]
    probes = []
    for t in targets:
        if ':' not in t:
            print(f'skip (no port): {t}', file=sys.stderr)
            continue
        host, port = t.rsplit(':', 1)
        result = probe_target(host, port, timeout=args.timeout)
        probes.append(result)
        if args.summary:
            tag = ''
            if result['pqc_only']:
                tag = ' [PQC-ONLY]'
            elif result['pqc_handshake_ok']:
                tag = ' [classical/hybrid OK]'
            else:
                tag = ' [HANDSHAKE FAILED]'
            sig = result['cert']['sig_algo'] if result['cert'] else '?'
            print(f'  {host}:{port}{tag} sig={sig}', file=sys.stderr)

    bom = to_cbom(probes)
    out = json.dumps(bom, indent=2)
    if args.output == '-':
        print(out)
    else:
        with open(args.output, 'w') as f:
            f.write(out)
        print(f'wrote {len(bom["components"])} components to {args.output}', file=sys.stderr)


if __name__ == '__main__':
    main()
