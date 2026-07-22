#!/usr/bin/env python3
"""Validate a CycloneDX 1.6 CBOM — crypto-specific correctness checks.

Usage:
    python3 cbom_validate.py cbom-one-tier-deduped.json
    python3 cbom_validate.py cbom.json --json
"""
import json
import sys
import argparse
from datetime import datetime, timedelta, timezone


VALID_PRIMITIVES = {
    'pke', 'mac', 'hash', 'signature', 'kdf', 'kem', 'ke', 'key-agree', 'cipher',
    'block-cipher', 'stream-cipher', 'aead', 'combiner', 'xof', 'other', 'unknown'
}

WEAK_ALGORITHMS = {'MD5', 'MD5-RSA', 'SHA1', 'SHA1-RSA', 'DES', '3DES', 'RC4', 'RC2'}

REQUIRED_TOP_LEVEL = ('bomFormat', 'specVersion', 'serialNumber', 'version', 'components')

REQUIRED_CERT_FIELDS = ('subjectName', 'notValidBefore', 'notValidAfter')


class Validator:
    def __init__(self, bom, path):
        self.bom = bom
        self.path = path
        self.results = []

        self.components = bom.get('components', [])
        self.ref_map = {c['bom-ref']: c for c in self.components if 'bom-ref' in c}
        self.dependencies = bom.get('dependencies', [])

        self.certs = [c for c in self.components
                      if c.get('cryptoProperties', {}).get('assetType') == 'certificate']
        self.algos = [c for c in self.components
                      if c.get('cryptoProperties', {}).get('assetType') == 'algorithm']
        self.keys = [c for c in self.components
                     if c.get('cryptoProperties', {}).get('assetType') == 'related-crypto-material']

    def add(self, level, check, message):
        self.results.append({'level': level, 'check': check, 'message': message})

    def check_top_level(self):
        for field in REQUIRED_TOP_LEVEL:
            if self.bom.get(field) is not None:
                self.add('PASS', 'top-level', f"Field '{field}' present")
            else:
                self.add('FAIL', 'top-level', f"Required field '{field}' missing")

        if self.bom.get('bomFormat') == 'CycloneDX':
            self.add('PASS', 'top-level', "bomFormat is 'CycloneDX'")
        else:
            self.add('FAIL', 'top-level', f"bomFormat is '{self.bom.get('bomFormat')}', expected 'CycloneDX'")

        sv = self.bom.get('specVersion', '')
        if sv:
            parts = [int(x) for x in sv.split('.')]
            if parts < [1, 6]:
                self.add('WARN', 'top-level', f"specVersion {sv} predates CBOM support (1.6+)")
            else:
                self.add('PASS', 'top-level', f"specVersion {sv}")

    def check_inventory(self):
        self.add('PASS', 'inventory',
                 f"Components: {len(self.components)} total "
                 f"({len(self.certs)} certs, {len(self.algos)} algorithms, {len(self.keys)} keys)")

    def check_bom_refs(self):
        all_refs = [c.get('bom-ref') for c in self.components if c.get('bom-ref')]
        unique_refs = set(all_refs)
        if len(all_refs) == len(unique_refs):
            self.add('PASS', 'bom-ref', f"All {len(all_refs)} bom-refs are unique")
        else:
            dupes = len(all_refs) - len(unique_refs)
            self.add('FAIL', 'bom-ref', f"{dupes} duplicate bom-ref values found")

        missing = [c for c in self.components if not c.get('bom-ref')]
        if missing:
            self.add('FAIL', 'bom-ref', f"{len(missing)} components missing bom-ref")
        else:
            self.add('PASS', 'bom-ref', "All components have bom-ref")

    def check_dependencies(self):
        errors = 0
        for dep in self.dependencies:
            # Malformed input must not crash the validator — surface as FAIL.
            ref = dep.get('ref')
            if ref is None:
                self.add('FAIL', 'deps', "Dependency missing 'ref' field")
                errors += 1
            elif ref not in self.ref_map:
                self.add('FAIL', 'deps', f"Dependency ref '{ref}' not found in components")
                errors += 1
            for target in dep.get('dependsOn', []):
                if target not in self.ref_map:
                    self.add('FAIL', 'deps', f"dependsOn ref '{target}' not found in components")
                    errors += 1
        if errors == 0 and self.dependencies:
            self.add('PASS', 'deps', f"All {len(self.dependencies)} dependency refs resolve")
        elif not self.dependencies:
            self.add('WARN', 'deps', "No dependencies defined")

    def check_cert_fields(self):
        ok = 0
        missing_count = 0
        for cert in self.certs:
            cp = cert.get('cryptoProperties', {}).get('certificateProperties')
            if not cp:
                self.add('FAIL', 'cert-fields',
                         f"Certificate '{cert.get('name', '?')}' missing certificateProperties")
                missing_count += 1
                continue
            missing = [f for f in REQUIRED_CERT_FIELDS if not cp.get(f)]
            if missing:
                missing_count += 1
            else:
                ok += 1
        if ok:
            self.add('PASS', 'cert-fields', f"{ok}/{len(self.certs)} certificates have all required fields")
        if missing_count:
            self.add('WARN', 'cert-fields', f"{missing_count}/{len(self.certs)} certificates missing fields")

    def check_cert_refs(self):
        sig_ok = sig_bad = pk_ok = pk_bad = 0
        for cert in self.certs:
            cp = cert.get('cryptoProperties', {}).get('certificateProperties', {})

            sig_ref = cp.get('signatureAlgorithmRef')
            if sig_ref:
                if sig_ref in self.ref_map:
                    sig_ok += 1
                else:
                    sig_bad += 1

            pk_ref = cp.get('subjectPublicKeyRef')
            if pk_ref:
                if pk_ref in self.ref_map:
                    pk_ok += 1
                else:
                    pk_bad += 1

        if sig_ok:
            self.add('PASS', 'cert-refs', f"{sig_ok} signatureAlgorithmRefs resolve")
        if sig_bad:
            self.add('FAIL', 'cert-refs', f"{sig_bad} signatureAlgorithmRefs point to missing components")
        if pk_ok:
            self.add('PASS', 'cert-refs', f"{pk_ok} subjectPublicKeyRefs resolve")
        if pk_bad:
            self.add('FAIL', 'cert-refs', f"{pk_bad} subjectPublicKeyRefs point to missing components")

    def check_algo_properties(self):
        ok = bad = missing = 0
        for algo in self.algos:
            ap = algo.get('cryptoProperties', {}).get('algorithmProperties')
            if not ap:
                missing += 1
                continue
            prim = ap.get('primitive')
            if prim:
                if prim in VALID_PRIMITIVES:
                    ok += 1
                else:
                    self.add('WARN', 'algo-props',
                             f"Algorithm '{algo.get('name')}' has unknown primitive '{prim}'")
                    bad += 1
            else:
                missing += 1
        if ok:
            self.add('PASS', 'algo-props', f"{ok}/{len(self.algos)} algorithms have valid primitive")
        if missing:
            self.add('WARN', 'algo-props', f"{missing}/{len(self.algos)} algorithms missing primitive")

    def check_key_sizes(self):
        ok = bad = missing = 0
        for key in self.keys:
            rp = key.get('cryptoProperties', {}).get('relatedCryptoMaterialProperties', {})
            size = rp.get('size')
            if size is None:
                missing += 1
            elif size <= 0:
                self.add('FAIL', 'key-size', f"Key '{key.get('name')}' has invalid size: {size}")
                bad += 1
            else:
                ok += 1
        if ok:
            self.add('PASS', 'key-size', f"{ok}/{len(self.keys)} keys have valid sizes")
        if missing:
            self.add('WARN', 'key-size', f"{missing}/{len(self.keys)} keys missing size")

    def check_weak_algorithms(self):
        found = {a.get('name') for a in self.algos if a.get('name') in WEAK_ALGORITHMS}
        if found:
            self.add('WARN', 'weak-algo', f"Weak algorithms present: {', '.join(sorted(found))}")
        else:
            self.add('PASS', 'weak-algo', "No weak algorithms detected")

        weak_keys = []
        for key in self.keys:
            rp = key.get('cryptoProperties', {}).get('relatedCryptoMaterialProperties', {})
            size = rp.get('size')
            if size and size < 2048 and 'RSA' in key.get('name', ''):
                weak_keys.append(size)
        if weak_keys:
            sizes = sorted(set(weak_keys))
            self.add('WARN', 'weak-key',
                     f"{len(weak_keys)} RSA keys < 2048 bits (sizes: {', '.join(str(s) for s in sizes)})")
        else:
            self.add('PASS', 'weak-key', "No RSA keys < 2048 bits")

    def check_private_keys(self):
        private = []
        for key in self.keys:
            rp = key.get('cryptoProperties', {}).get('relatedCryptoMaterialProperties', {})
            if rp.get('type') == 'private-key':
                locations = [o.get('location', '?')
                             for o in key.get('evidence', {}).get('occurrences', [])]
                private.extend(locations)
        if private:
            self.add('WARN', 'private-key', f"{len(private)} private key(s) found: {', '.join(private)}")
        else:
            self.add('PASS', 'private-key', "No private keys detected")

    def check_cert_expiry(self):
        now = datetime.now(timezone.utc)
        expired = 0
        expiring_soon = 0
        for cert in self.certs:
            cp = cert.get('cryptoProperties', {}).get('certificateProperties', {})
            nva = cp.get('notValidAfter')
            if not nva:
                continue
            try:
                expiry = datetime.fromisoformat(nva.replace('Z', '+00:00'))
                if expiry < now:
                    expired += 1
                elif expiry < now + timedelta(days=30):
                    expiring_soon += 1
            except (ValueError, TypeError):
                pass
        if expired:
            self.add('WARN', 'cert-expiry', f"{expired} certificate(s) already expired")
        if expiring_soon:
            self.add('WARN', 'cert-expiry', f"{expiring_soon} certificate(s) expiring within 30 days")
        if not expired and not expiring_soon:
            self.add('PASS', 'cert-expiry', "No certificates expired or expiring within 30 days")

    def run_all(self):
        self.check_top_level()
        self.check_inventory()
        self.check_bom_refs()
        self.check_dependencies()
        self.check_cert_fields()
        self.check_cert_refs()
        self.check_algo_properties()
        self.check_key_sizes()
        self.check_weak_algorithms()
        self.check_private_keys()
        self.check_cert_expiry()
        return self.results


def main():
    parser = argparse.ArgumentParser(description="Validate a CycloneDX CBOM")
    parser.add_argument("input", help="CBOM JSON file")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    with open(args.input) as f:
        bom = json.load(f)

    v = Validator(bom, args.input)
    results = v.run_all()

    counts = {'PASS': 0, 'WARN': 0, 'FAIL': 0}
    for r in results:
        counts[r['level']] += 1

    if args.json:
        print(json.dumps({
            'file': args.input,
            'pass': counts['PASS'],
            'warn': counts['WARN'],
            'fail': counts['FAIL'],
            'results': results
        }, indent=2))
    else:
        colors = {'PASS': '\033[32m', 'WARN': '\033[33m', 'FAIL': '\033[31m'}
        reset = '\033[0m'
        for r in results:
            print(f"  {colors[r['level']]}{r['level']:4s}{reset}  [{r['check']}] {r['message']}")
        print()
        print(f"  Summary: "
              f"\033[32mPASS: {counts['PASS']}\033[0m  "
              f"\033[33mWARN: {counts['WARN']}\033[0m  "
              f"\033[31mFAIL: {counts['FAIL']}\033[0m")

    sys.exit(1 if counts['FAIL'] > 0 else 0)


if __name__ == '__main__':
    main()
