#!/usr/bin/env python3
"""Probe OpenPGP keys across lab hosts via GnuPG colon-format output.

Sister to pqc_handshake_probe.py (TLS) and pqc_ssh_probe.py (SSH).
For each target host, SSHs in and runs
`/opt/gnupg-pqc/bin/gpg --list-keys --with-colons`. Parses the output:
- pub records → primary key components
- sub records → subkey components, including Kyber (algo 8) subkeys
- fpr records → fingerprints (used as bom-ref source)

Kyber subkeys (the PQC half of an ECC+Kyber composite) get tagged
`[PQC-KYBER]` on the component name so cbom_ingest derives
cbom_pqc_only:true. Aligns with the [PQC-ONLY] / [PQC-STANDARD] tagging
the TLS + SSH scanners use.

Runs from the orchestrator (cbom-pipeline.sh), not on the target — uses
ssh to fetch each host's --list-keys output.

Usage:
    python3 pqc_openpgp_probe.py \\
        --targets observe1=192.168.56.53,stepca1=192.168.56.51,... \\
        --ssh-key /path/to/key \\
        --gpg-bin /opt/gnupg-pqc/bin/gpg \\
        --gpg-homedir /opt/gnupg-pqc/home
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import uuid

# GnuPG pubkey algorithm enum (RFC 4880 + RFC 9580):
#   1=RSA, 17=DSA, 18=ECDH, 19=ECDSA, 22=EdDSA, 8=Kyber
# RFC 9580 will eventually allocate ML-KEM/ML-DSA codepoints; until then
# GnuPG reuses 8 for the composite ECC+Kyber.
GPG_ALGO = {
    '1':  ('RSA',         'quantum-vulnerable'),
    '17': ('DSA',         'quantum-vulnerable'),
    '18': ('ECDH',        'quantum-vulnerable'),
    '19': ('ECDSA',       'quantum-vulnerable'),
    '22': ('EdDSA',       'quantum-vulnerable'),
    '8':  ('Kyber',       'quantum-safe'),   # PQC encryption
    # When ML-DSA lands: '20' / '21' / etc. for ML-DSA variants
}

USAGE_FLAGS = {
    'e': 'encrypt',
    'E': 'encrypt-cert',
    's': 'sign',
    'S': 'sign-cert',
    'c': 'certify',
    'C': 'certify-cert',
    'a': 'auth',
    'A': 'auth-cert',
}


def parse_colons(text):
    """Parse `gpg --list-keys --with-colons` output. Returns list of dicts,
    each = {kind, algo_id, length, keyid, fpr, usage, curve, uids: [...]}."""
    records = []
    current = None
    last_fpr = None
    for line in text.splitlines():
        cols = line.split(':')
        # Truncated / malformed colon records crashed the whole probe with
        # IndexError pre-fix. GnuPG's colon format documents 20 fields but
        # we've seen 12-13 column records from stripped output. Need at
        # least cols[0..11] for pub/sub; cols[16] (curve) is opportunistic.
        if len(cols) < 12:
            continue
        kind = cols[0]
        if kind == 'pub' or kind == 'sub':
            curve = cols[16] if len(cols) > 16 else ''
            current = {
                'kind': kind,
                'length': cols[2],
                'algo_id': cols[3],
                'keyid': cols[4],
                'created': cols[5],
                'expires': cols[6],
                'usage': cols[11],
                'curve': curve,
                'fpr': None,
                'uids': [],
            }
            records.append(current)
        elif kind == 'fpr' and current is not None and current.get('fpr') is None:
            current['fpr'] = cols[9]
        elif kind == 'uid' and current is not None and current['kind'] == 'pub':
            current['uids'].append(cols[9])
    return records


def probe_host(name, ip, ssh_key, gpg_bin, gpg_homedir, timeout=10):
    """SSH into a host, fetch gpg --list-keys --with-colons, parse it."""
    cmd = [
        'ssh',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', f'ConnectTimeout={timeout-2}',
        '-i', ssh_key,
        f'vagrant@{ip}',
        f'sudo {gpg_bin} --homedir {gpg_homedir} --list-keys --with-colons',
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0:
            return {'host': name, 'ip': ip, 'error': p.stderr.strip()[:200], 'records': []}
        return {'host': name, 'ip': ip, 'records': parse_colons(p.stdout)}
    except subprocess.TimeoutExpired:
        return {'host': name, 'ip': ip, 'error': 'timeout', 'records': []}
    except FileNotFoundError as e:
        return {'host': name, 'ip': ip, 'error': f'ssh not found: {e}', 'records': []}


def to_cbom(probes):
    """Emit one component per (host, key/subkey)."""
    components = []
    for p in probes:
        host = p['host']
        ip = p.get('ip', host)
        # location format aligns with cbom_score.py's VM grouping
        # ("vm/identifier"); use host as the VM, "openpgp:<fpr>" as the
        # specific instance.
        for rec in p['records']:
            algo_name, pqc_status = GPG_ALGO.get(rec['algo_id'], (f'algo-{rec["algo_id"]}', 'unknown'))
            # Curve override — Kyber records carry curve='ky768_bp256' etc.
            display_algo = rec['curve'] if rec['curve'] else algo_name
            is_pqc = pqc_status == 'quantum-safe'
            tag = '[PQC-KYBER] ' if is_pqc else ''

            usage = ','.join(USAGE_FLAGS.get(u, u) for u in rec['usage'])
            uid_str = (rec['uids'][0] if rec['uids'] else '')[:60]

            location = f'{host}/openpgp:{rec["keyid"]}'
            ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:{display_algo}'))
            cert_or_alg = 'algorithm'  # treat each key as an algorithm component
                                       # (it has a primitive); cbom_ingest's
                                       # certificate-specific fields don't apply

            primitive = 'signature' if 's' in rec['usage'].lower() and not is_pqc \
                        else 'key-agree' if is_pqc \
                        else 'pke'
            components.append({
                'bom-ref': ref,
                'type': 'cryptographic-asset',
                'name': f'{tag}{display_algo} ({rec["kind"]}, {usage})' + (f' — {uid_str}' if uid_str and rec['kind']=='pub' else ''),
                'evidence': {'occurrences': [{'location': location}]},
                'cryptoProperties': {
                    'assetType': 'algorithm',
                    'algorithmProperties': {
                        'primitive': primitive,
                        'parameterSetIdentifier': 'OpenPGP-v4',
                        'cryptoFunctions': ['sign'] if 's' in rec['usage'].lower() else ['encapsulate'],
                    },
                },
            })

    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    return {
        '$schema': 'https://cyclonedx.org/schema/bom-1.6.schema.json',
        'bomFormat': 'CycloneDX',
        'specVersion': '1.6',
        'serialNumber': 'urn:uuid:' + str(uuid.uuid4()),
        'version': 1,
        'metadata': {
            'timestamp': timestamp,
            'component': {
                'type': 'application',
                'name': 'pqc-openpgp-probe',
                'version': '1.0.0',
            },
        },
        'components': components,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--targets', required=True,
                    help='Comma-sep host=ip pairs, e.g. observe1=192.168.56.53,stepca1=192.168.56.51')
    ap.add_argument('--ssh-key-dir', required=True,
                    help='Path to directory containing per-host SSH keys (.vagrant/machines/<vm>/virtualbox/private_key)')
    ap.add_argument('--gpg-bin',     default='/opt/gnupg-pqc/bin/gpg')
    ap.add_argument('--gpg-homedir', default='/opt/gnupg-pqc/home')
    ap.add_argument('-o', '--output', default='-')
    ap.add_argument('--summary', action='store_true')
    args = ap.parse_args()

    targets = []
    for pair in args.targets.split(','):
        pair = pair.strip()
        if '=' not in pair:
            print(f'skip (no =): {pair}', file=sys.stderr)
            continue
        name, ip = pair.split('=', 1)
        targets.append((name, ip))

    probes = []
    for name, ip in targets:
        ssh_key = f'{args.ssh_key_dir}/{name}/virtualbox/private_key'
        if not os.path.isfile(ssh_key):
            print(f'  skip {name}: no key at {ssh_key}', file=sys.stderr)
            continue
        result = probe_host(name, ip, ssh_key, args.gpg_bin, args.gpg_homedir)
        probes.append(result)
        if args.summary:
            if 'error' in result:
                print(f'  {name} ({ip}): ERROR {result["error"]}', file=sys.stderr)
            else:
                kybers = sum(1 for r in result['records'] if r['algo_id'] == '8')
                total = len(result['records'])
                print(f'  {name} ({ip}): {total} records, {kybers} Kyber subkey(s)', file=sys.stderr)

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
