#!/usr/bin/env python3
"""Probe TLS endpoints via openssl s_client to detect key-exchange groups.

nmap's ssl-enum-ciphers reports TLS 1.3 cipher suites but not the key
exchange group negotiated underneath.  This script uses `openssl s_client`
to attempt TLS handshakes with specific groups and records which ones
succeed — including PQC hybrid groups like X25519MLKEM768.

Designed to run on scanner1 (Ubuntu) where OpenSSL 3.5+ is available.
Falls back gracefully if openssl lacks PQC group support.

Usage:
    python3 kex_probe.py --targets 192.168.56.10:636,192.168.56.50:8443
    python3 kex_probe.py --targets-file targets.txt -o kex-results.json
"""
import argparse
import json
import os
import subprocess
import sys

OPENSSL_BIN = os.environ.get('OPENSSL_BIN', 'openssl')

# TLS 1.3 key exchange groups to probe, ordered classical → hybrid → pure PQC
KEX_GROUPS = [
    # Classical (baseline — always succeeds if TLS 1.3 works)
    'X25519',
    'P-256',
    'P-384',
    # PQC hybrid (OpenSSL 3.5+)
    'X25519MLKEM768',
    'SecP256r1MLKEM768',
    # Pure PQC (OpenSSL 3.5+)
    'MLKEM768',
    'MLKEM1024',
]


def probe_endpoint(host, port, groups=None, timeout=5):
    """Probe a single host:port for each KEX group.

    Returns list of dicts with successful group negotiations.
    """
    if groups is None:
        groups = KEX_GROUPS

    results = []
    for group in groups:
        cmd = [
            OPENSSL_BIN, 's_client',
            '-connect', f'{host}:{port}',
            '-groups', group,
            '-brief',
        ]
        try:
            proc = subprocess.run(
                cmd,
                input=b'',
                capture_output=True,
                timeout=timeout,
            )
            output = proc.stdout.decode('utf-8', errors='replace')
            stderr = proc.stderr.decode('utf-8', errors='replace')
            combined = output + stderr

            # Check for successful handshake
            if 'CONNECTION ESTABLISHED' in combined or 'Protocol  : TLSv1.3' in combined:
                protocol = 'TLSv1.3'
                cipher = ''
                for line in combined.splitlines():
                    if 'Protocol' in line and ':' in line:
                        protocol = line.split(':', 1)[1].strip()
                    if 'Ciphersuite' in line and ':' in line:
                        cipher = line.split(':', 1)[1].strip()
                results.append({
                    'ip': host,
                    'port': str(port),
                    'group': group,
                    'protocol': protocol,
                    'cipher': cipher,
                })
        except subprocess.TimeoutExpired:
            continue
        except FileNotFoundError:
            print('openssl not found', file=sys.stderr)
            return results

    return results


def parse_targets(target_str):
    """Parse comma-separated host:port targets."""
    targets = []
    for t in target_str.split(','):
        t = t.strip()
        if not t:
            continue
        if ':' in t:
            host, port = t.rsplit(':', 1)
            targets.append((host, int(port)))
        else:
            # Default to 443
            targets.append((t, 443))
    return targets


def main():
    parser = argparse.ArgumentParser(description='Probe TLS key-exchange groups via openssl')
    parser.add_argument('--targets', help='Comma-separated host:port list')
    parser.add_argument('--targets-file', help='File with one host:port per line')
    parser.add_argument('--groups', help='Comma-separated KEX groups to probe (default: all)')
    parser.add_argument('--timeout', type=int, default=5, help='Per-probe timeout in seconds')
    parser.add_argument('-o', '--output', help='Output JSON file (default: stdout)')
    args = parser.parse_args()

    targets = []
    if args.targets:
        targets = parse_targets(args.targets)
    if args.targets_file:
        with open(args.targets_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    targets.extend(parse_targets(line))

    if not targets:
        print('No targets specified. Use --targets or --targets-file.', file=sys.stderr)
        sys.exit(1)

    groups = None
    if args.groups:
        groups = [g.strip() for g in args.groups.split(',')]

    all_results = []
    for host, port in targets:
        print(f'  Probing {host}:{port}...', file=sys.stderr)
        results = probe_endpoint(host, port, groups=groups, timeout=args.timeout)
        pqc_groups = [r['group'] for r in results
                      if 'MLKEM' in r['group'] or 'mlkem' in r['group'].lower()]
        if pqc_groups:
            print(f'    PQC KEX: {", ".join(pqc_groups)}', file=sys.stderr)
        elif results:
            print(f'    Classical only: {", ".join(r["group"] for r in results)}', file=sys.stderr)
        else:
            print(f'    No TLS 1.3 handshake', file=sys.stderr)
        all_results.extend(results)

    output = json.dumps(all_results, indent=2)
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
        print(f'  Wrote {len(all_results)} results to {args.output}', file=sys.stderr)
    else:
        print(output)


if __name__ == '__main__':
    main()
