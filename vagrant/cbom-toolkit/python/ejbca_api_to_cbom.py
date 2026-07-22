#!/usr/bin/env python3
"""Query EJBCA CE via SSH/CLI and produce CycloneDX CBOM 1.6 JSON.

nmap 7.80 with OpenSSL 3.0 cannot complete TLS handshakes with ML-DSA server
certs.  This scanner bypasses TLS entirely by shelling into the EJBCA VM and
running ejbca.sh commands directly, so PQC CAs are always discoverable.

Usage:
    python3 ejbca_api_to_cbom.py > cbom-ejbca.json
    python3 ejbca_api_to_cbom.py --ejbca-host 192.168.56.50 -o cbom-ejbca.json
"""
import json
import subprocess
import sys
import uuid
import argparse
from datetime import datetime, timezone

# ── PQC OID → algorithm name map ─────────────────────────────────────────────

PQC_OIDS = {
    '2.16.840.1.101.3.4.3.17': 'ML-DSA-44',
    '2.16.840.1.101.3.4.3.18': 'ML-DSA-65',
    '2.16.840.1.101.3.4.3.19': 'ML-DSA-87',
}

# ── PQC algorithm keyword detection ──────────────────────────────────────────

PQC_KEYWORDS = ('ML-DSA', 'SLH-DSA', 'Dilithium', 'Falcon')


def is_pqc(algo_string):
    """Return True if the algorithm string indicates a PQC algorithm."""
    return any(kw in algo_string for kw in PQC_KEYWORDS)


# ── SSH helpers ───────────────────────────────────────────────────────────────

def _ssh_opts(host, key_path):
    return [
        'ssh',
        '-o', 'ConnectTimeout=10',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'BatchMode=yes',
        '-i', key_path,
        f'vagrant@{host}',
    ]


def ejbca_cmd(host, key_path, *args):
    """Run an ejbca.sh subcommand via SSH inside the ejbca-ce container.

    Returns (stdout, stderr, returncode).
    """
    container_cmd = (
        'docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ' + ' '.join(args)
    )
    proc = subprocess.run(
        _ssh_opts(host, key_path) + [container_cmd],
        capture_output=True,
        text=True,
    )
    return proc.stdout, proc.stderr, proc.returncode


# ── EJBCA output parsers ──────────────────────────────────────────────────────

def list_cas(host, key_path):
    """Return a list of CA names from `ejbca.sh ca listcas`."""
    stdout, stderr, rc = ejbca_cmd(host, key_path, 'ca', 'listcas')
    if rc != 0:
        raise RuntimeError(f'ejbca.sh ca listcas failed (rc={rc}): {stderr.strip()}')

    names = []
    for line in stdout.splitlines():
        # EJBCA CLI prefixes output with timestamp + log level, e.g.:
        # "2026-04-12 16:35:33,387+0000 INFO  [...] (main) CA Name: EJBCA-Root-CA"
        if 'CA Name:' in line:
            name = line.split('CA Name:', 1)[1].strip()
            if name:
                names.append(name)
    return names


def ca_info(host, key_path, ca_name):
    """Return raw output of `ejbca.sh ca info --caname <name>`."""
    stdout, stderr, rc = ejbca_cmd(host, key_path, 'ca', 'info', '--caname', ca_name)
    if rc != 0:
        raise RuntimeError(
            f'ejbca.sh ca info --caname {ca_name!r} failed (rc={rc}): {stderr.strip()}'
        )
    return stdout


def parse_ca_info(raw):
    """Extract key fields from `ca info` output.

    Returns a dict with keys: subject_dn, issuer_dn, sig_algo, pk_algo,
    not_before, not_after.  Missing fields are empty strings / None.
    """
    fields = {
        'subject_dn': '',
        'issuer_dn': '',
        'sig_algo': '',
        'pk_algo': '',
        'not_before': None,
        'not_after': None,
    }
    for line in raw.splitlines():
        # Strip EJBCA log prefix: "2026-... INFO  [...] (main) <actual content>"
        payload = line
        if '(main)' in line:
            payload = line.split('(main)', 1)[1].strip()
        payload_lower = payload.lower()

        # Subject / Issuer — EJBCA uses "Root CA DN:" or "Subject DN:"
        if 'subject dn:' in payload_lower or payload_lower.startswith('subject:'):
            fields['subject_dn'] = payload.split('DN:', 1)[1].strip() if 'DN:' in payload else payload.split(':', 1)[1].strip()
        elif 'issuer dn:' in payload_lower or payload_lower.startswith('issuer:'):
            fields['issuer_dn'] = payload.split('DN:', 1)[1].strip() if 'DN:' in payload else payload.split(':', 1)[1].strip()
        elif 'root ca dn:' in payload_lower and not fields['subject_dn']:
            fields['subject_dn'] = payload.split('DN:', 1)[1].strip()

        # Signature algorithm
        elif 'signature algorithm' in payload_lower:
            fields['sig_algo'] = payload.rsplit(':', 1)[1].strip()

        # Key algorithm — EJBCA 9.3 uses "Root CA key algorithm: ML-DSA-65"
        elif 'key algorithm' in payload_lower:
            fields['pk_algo'] = payload.rsplit(':', 1)[1].strip()
            # If no sig_algo found yet, key algorithm is a good proxy
            if not fields['sig_algo']:
                fields['sig_algo'] = fields['pk_algo']

        # Validity dates
        elif 'valid from:' in payload_lower or 'not before' in payload_lower:
            fields['not_before'] = payload.rsplit(':', 1)[1].strip()
        elif 'valid to:' in payload_lower or 'not after' in payload_lower:
            fields['not_after'] = payload.rsplit(':', 1)[1].strip()

    # If no sig_algo found, check PQC OID map via a second pass
    if not fields['sig_algo']:
        for line in raw.splitlines():
            for oid, name in PQC_OIDS.items():
                if oid in line:
                    fields['sig_algo'] = name
                    break

    return fields


# ── CBOM builder ──────────────────────────────────────────────────────────────

def build_components(ca_name, info, location):
    """Return a list of CBOM components (sig-algo, key, cert) for one CA."""
    components = []
    sig_algo = info['sig_algo'] or 'Unknown'
    pk_algo = info['pk_algo'] or sig_algo

    # ── Signature algorithm component ──────────────────────────────────────
    sig_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:sig:{sig_algo}'))
    components.append({
        'bom-ref': sig_ref,
        'type': 'cryptographic-asset',
        'name': sig_algo,
        'evidence': {'occurrences': [{'location': location}]},
        'cryptoProperties': {
            'assetType': 'algorithm',
            'algorithmProperties': {
                'primitive': 'signature',
                'cryptoFunctions': ['sign'],
            },
        },
    })

    # ── Public key component ────────────────────────────────────────────────
    pk_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:pk:{ca_name}:{pk_algo}'))
    pk_component = {
        'bom-ref': pk_ref,
        'type': 'cryptographic-asset',
        'name': pk_algo,
        'evidence': {'occurrences': [{'location': location}]},
        'cryptoProperties': {
            'assetType': 'related-crypto-material',
            'relatedCryptoMaterialProperties': {
                'type': 'public-key',
            },
        },
    }
    components.append(pk_component)

    # ── Certificate component ───────────────────────────────────────────────
    cert_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:cert:{ca_name}'))
    cert_props = {
        'subjectName': info['subject_dn'] or ca_name,
        'issuerName': info['issuer_dn'] or ca_name,
        'certificateFormat': 'X.509',
        'signatureAlgorithmRef': sig_ref,
        'subjectPublicKeyRef': pk_ref,
    }
    if info.get('not_before'):
        cert_props['notValidBefore'] = info['not_before']
    if info.get('not_after'):
        cert_props['notValidAfter'] = info['not_after']

    components.append({
        'bom-ref': cert_ref,
        'type': 'cryptographic-asset',
        'name': ca_name,
        'evidence': {'occurrences': [{'location': location}]},
        'cryptoProperties': {
            'assetType': 'certificate',
            'certificateProperties': cert_props,
        },
    })

    return components


def build_cbom(all_components, ejbca_host):
    return {
        '$schema': 'https://cyclonedx.org/schema/bom-1.6.schema.json',
        'bomFormat': 'CycloneDX',
        'specVersion': '1.6',
        'serialNumber': f'urn:uuid:{uuid.uuid4()}',
        'version': 1,
        'metadata': {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'component': {
                'type': 'application',
                'name': 'ejbca-api-scan',
                'version': '1.0',
            },
        },
        'components': all_components,
    }


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Query EJBCA CE via CLI and produce CycloneDX CBOM 1.6'
    )
    parser.add_argument(
        '--ejbca-host',
        default='192.168.56.50',
        help='EJBCA VM IP (default: 192.168.56.50)',
    )
    parser.add_argument(
        '--ejbca-key',
        default='.vagrant-1t/machines/ejbca1/virtualbox/private_key',
        help='Path to SSH private key for the EJBCA VM',
    )
    parser.add_argument(
        '-o', '--output',
        help='Output JSON file (default: stdout)',
    )
    args = parser.parse_args()

    location = f'ejbca1/{args.ejbca_host}:8443'

    # ── Discover CAs ─────────────────────────────────────────────────────────
    try:
        ca_names = list_cas(args.ejbca_host, args.ejbca_key)
    except RuntimeError as exc:
        print(f'ERROR listing CAs: {exc}', file=sys.stderr)
        sys.exit(1)

    if not ca_names:
        print('WARNING: no CAs found in EJBCA', file=sys.stderr)

    # ── Collect components ────────────────────────────────────────────────────
    all_components = []
    pqc_count = 0

    for name in ca_names:
        try:
            raw = ca_info(args.ejbca_host, args.ejbca_key, name)
        except RuntimeError as exc:
            print(f'  WARNING: skipping CA {name!r}: {exc}', file=sys.stderr)
            continue

        info = parse_ca_info(raw)
        components = build_components(name, info, location)
        all_components.extend(components)

        algo = info['sig_algo']
        pqc_flag = ' [PQC]' if is_pqc(algo) else ''
        print(f'  CA: {name}  algo={algo}{pqc_flag}', file=sys.stderr)
        if is_pqc(algo):
            pqc_count += 1

    bom = build_cbom(all_components, args.ejbca_host)
    output = json.dumps(bom, indent=2)

    if args.output:
        with open(args.output, 'w') as fh:
            fh.write(output)
        print(
            f'  Wrote {len(all_components)} components '
            f'({pqc_count} PQC CA(s)) to {args.output}',
            file=sys.stderr,
        )
    else:
        print(output)


if __name__ == '__main__':
    main()
