#!/usr/bin/env python3
"""Probe SSH KEX algorithms across lab hosts and emit CycloneDX 1.6 CBOM.

Sister to pqc_handshake_probe.py — that one handles TLS, this handles SSH.
For each target host:port, runs `ssh -v -o KexAlgorithms=<algo>` against
each candidate KEX and records which ones succeeded. Hybrid PQC KEX
(`mlkem768x25519-sha256`, the NIST-standardized one in OpenSSH 10.0+) and
the pre-standard PQC KEX (`sntrup761x25519-sha512@openssh.com`) are
tagged `[PQC-PROTECTED]` on the CBOM component so cbom_ingest derives
`cbom_pqc_only:true` for them.

Designed to run on a host with OpenSSH 10+ (observe1 in the lab). Falls
back to system ssh for non-PQC probes.

Usage:
    python3 pqc_ssh_probe.py --targets 192.168.56.50:2222,192.168.56.51:2222
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import uuid

# Path to a PQC-aware ssh client (OpenSSH 10+). Falls back to system ssh
# for classical-only probes if SSH_PQC_BIN doesn't exist.
SSH_PQC = os.environ.get('SSH_PQC_BIN', '/opt/openssh-10/bin/ssh')
SSH_SYS = os.environ.get('SSH_SYS_BIN', 'ssh')

# Ordered probe — first match wins as the "preferred" algo.
KEX_PROBES = [
    # (algo name, classifier tag)
    ('mlkem768x25519-sha256', 'pqc-standard'),       # NIST ML-KEM hybrid
    ('sntrup761x25519-sha512@openssh.com', 'pqc-legacy'),  # pre-standard PQC
    ('curve25519-sha256', 'classical'),
    ('ecdh-sha2-nistp256', 'classical'),
]


def run(cmd, timeout=8, stdin=''):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=stdin)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, '', 'timeout'
    except FileNotFoundError:
        return 127, '', 'binary-not-found'


def probe_kex(ssh_bin, host, port, algo, timeout=6):
    """Try a single KEX algo. Returns True iff the server negotiated it.
    Auth always fails (BatchMode + nobody user) — we only care about the
    `kex: algorithm: <algo>` line in stderr."""
    if not os.path.exists(ssh_bin) and ssh_bin != 'ssh':
        return False
    cmd = [
        ssh_bin, '-v', '-p', str(port),
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', f'KexAlgorithms={algo}',
        '-o', f'ConnectTimeout={timeout-1}',
        f'nobody@{host}', 'echo', 'ok',
    ]
    _, out, err = run(cmd, timeout=timeout)
    blob = (out or '') + (err or '')
    needle = f'kex: algorithm: {algo}'
    return needle in blob


def probe_target(host, port, timeout=8):
    """Probe a single host:port across all KEX_PROBES. Returns dict."""
    pqc_available = os.path.exists(SSH_PQC)
    results = []
    for algo, tag in KEX_PROBES:
        # mlkem768 needs the PQC-aware client; others can fall back to sys.
        client = SSH_PQC if (pqc_available and tag.startswith('pqc')) else SSH_SYS
        ok = probe_kex(client, host, port, algo, timeout=timeout)
        results.append({'algo': algo, 'tag': tag, 'negotiated': ok, 'client': client})
    return {
        'host': host,
        'port': int(port),
        'pqc_client_available': pqc_available,
        'kex': results,
        'pqc_standard_ok': any(r['negotiated'] for r in results if r['tag'] == 'pqc-standard'),
        'pqc_legacy_ok': any(r['negotiated'] for r in results if r['tag'] == 'pqc-legacy'),
        'classical_ok': any(r['negotiated'] for r in results if r['tag'] == 'classical'),
    }


def to_cbom(probes):
    """Emit one component per (host, KEX algo successfully negotiated)."""
    components = []
    for p in probes:
        host, port = p['host'], p['port']
        location = f'{host}/{host}:{port}'
        for r in p['kex']:
            if not r['negotiated']:
                continue
            algo = r['algo']
            # Mark PQC-only when this host *only* negotiates a PQC KEX
            # (i.e. classical wouldn't work). Mostly false in our lab —
            # OpenSSH still accepts classical KEX too — but the field is
            # informative.
            tag_prefix = ''
            if r['tag'] == 'pqc-standard':
                tag_prefix = '[PQC-STANDARD] '   # mlkem768 — the headline
            elif r['tag'] == 'pqc-legacy':
                tag_prefix = '[PQC-LEGACY] '     # sntrup761 — pre-standard
            ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:ssh-kex:{algo}'))
            components.append({
                'bom-ref': ref,
                'type': 'cryptographic-asset',
                'name': f'{tag_prefix}{algo}',
                'evidence': {'occurrences': [{'location': location}]},
                'cryptoProperties': {
                    'assetType': 'algorithm',
                    'algorithmProperties': {
                        'primitive': 'key-agree',
                        'cryptoFunctions': ['encapsulate'],
                        'parameterSetIdentifier': 'SSH-Transport',
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
                'name': 'pqc-ssh-probe',
                'version': '1.0.0',
            },
        },
        'components': components,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--targets', required=True, help='Comma-separated host:port pairs')
    ap.add_argument('-o', '--output', default='-')
    ap.add_argument('--timeout', type=int, default=8)
    ap.add_argument('--summary', action='store_true')
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
            algos = ','.join(r['algo'] for r in result['kex'] if r['negotiated'])
            tag = '[PQC-STANDARD]' if result['pqc_standard_ok'] else \
                  '[PQC-LEGACY]' if result['pqc_legacy_ok'] else \
                  '[classical-only]'
            print(f'  {host}:{port} {tag} algos=[{algos}]', file=sys.stderr)

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
