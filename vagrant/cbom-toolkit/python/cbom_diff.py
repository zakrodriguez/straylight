#!/usr/bin/env python3
"""Diff two CycloneDX CBOMs to detect cryptographic changes.

Usage:
    python3 cbom_diff.py baseline.json current.json
    python3 cbom_diff.py baseline.json current.json --json
"""
import json
import sys
import re
import argparse


# Certificate fields that change on every re-issuance and carry no crypto
# identity — excluded from the fingerprint so a rebuilt lab's freshly-issued
# certs don't read as drift.
_VOLATILE_CERT_FIELDS = ("notValidBefore", "notValidAfter")

# Certificate DN fields whose *content* is stable identity but whose textual
# form churns per-deployment — canonicalized (not dropped) so re-serialization
# noise doesn't read as drift. See _canonical_dn.
_DN_CERT_FIELDS = ("subjectName", "issuerName")

# The EJBCA/PrimeKey Quickstart container mints a fresh ManagementCA userId
# ("c-<16+ base36 chars>") on every redeploy; it is embedded in that CA's DN
# but carries no crypto identity, so it's masked to a constant.
_CONTAINER_UID_RE = re.compile(r"c-[a-z0-9]{16,}")

# Split a DN on the comma that precedes an RDN attribute ("key=") only, so a
# comma *inside* a value ("O=Acme, Inc.") does not tear the value apart.
_RDN_SPLIT_RE = re.compile(r",\s*(?=[A-Za-z0-9.]+=)")


def _canonical_dn(dn):
    """Canonicalize a distinguished-name string for stable comparison:
    mask the per-deployment EJBCA container UID and sort the RDN components,
    so a scanner emitting the same DN with a churny UID or a different RDN
    order still matches. Different DN *content* still produces a different
    canonical form, so genuine identity changes are preserved."""
    dn = _CONTAINER_UID_RE.sub("c-<CONTAINER-UID>", dn)
    parts = [p.strip() for p in _RDN_SPLIT_RE.split(dn)]
    return ", ".join(sorted(parts))


def _canonical_crypto(cp, ref_names):
    """A stable identity view of a component's cryptoProperties:

    - drop per-issuance certificate validity timestamps, and
    - resolve every `*Ref` pointer (a churny per-component bom-ref UUID) to the
      NAME of the component it points at.

    A cert re-issued with a fresh keypair points its subjectPublicKeyRef at a
    NEW key component — but that key's name (e.g. "id-ecPublicKey") is stable,
    so resolving the ref keeps identity stable across re-issuance while a
    genuine algorithm/key change (a different resolved name) still shows up.
    An unresolvable ref maps to a constant so dangling pointers stay stable.
    """
    def canon(obj):
        if isinstance(obj, dict):
            out = {}
            for k, v in obj.items():
                if k.endswith("Ref") and isinstance(v, str):
                    out[k] = ref_names.get(v, "<unresolved-ref>")
                else:
                    out[k] = canon(v)
            return out
        if isinstance(obj, list):
            return [canon(x) for x in obj]
        return obj

    cp = canon(cp)
    certp = cp.get("certificateProperties")
    if isinstance(certp, dict):
        for k in _VOLATILE_CERT_FIELDS:
            certp.pop(k, None)
        for k in _DN_CERT_FIELDS:
            v = certp.get(k)
            if isinstance(v, str):
                certp[k] = _canonical_dn(v)
    return cp


def get_fingerprint(component, ref_names=None):
    """Identity = STABLE cryptoProperties content (see _canonical_crypto).
    Components without cryptoProperties fall back to their name."""
    ref_names = ref_names or {}
    cp = component.get('cryptoProperties')
    if cp:
        return json.dumps(_canonical_crypto(cp, ref_names), sort_keys=True)
    return component.get('name', '')


def _ref_names(bom):
    """Map every component's bom-ref -> its name, for ref resolution."""
    return {c.get("bom-ref"): c.get("name", "")
            for c in bom.get("components", []) if c.get("bom-ref")}


def get_asset_type(component):
    return component.get('cryptoProperties', {}).get('assetType')


def get_cert_summary(component):
    cp = component.get('cryptoProperties', {}).get('certificateProperties', {})
    subject = cp.get('subjectName') or component.get('name', '?')
    issuer = cp.get('issuerName', '?')
    expiry = cp.get('notValidAfter', '?')
    return f"{subject} (issuer: {issuer}, expires: {expiry})"


def get_key_summary(component):
    rp = component.get('cryptoProperties', {}).get('relatedCryptoMaterialProperties', {})
    ktype = rp.get('type', '?')
    size = rp.get('size', '?')
    return f"{component.get('name', '?')} ({ktype}, {size}-bit)"


def get_location(component):
    for occ in component.get('evidence', {}).get('occurrences', []):
        loc = occ.get('location')
        if loc:
            return loc
    return '?'


def diff_cboms(before_path, after_path):
    with open(before_path) as f:
        bom_before = json.load(f)
    with open(after_path) as f:
        bom_after = json.load(f)
    result = diff_from_boms(bom_before, bom_after)
    result['before'] = before_path
    result['after'] = after_path
    return result


def diff_from_boms(bom_before, bom_after):
    before_refs = _ref_names(bom_before)
    after_refs = _ref_names(bom_after)
    before_index = {get_fingerprint(c, before_refs): c for c in bom_before.get('components', [])}
    after_index = {get_fingerprint(c, after_refs): c for c in bom_after.get('components', [])}

    added = [after_index[fp] for fp in after_index if fp not in before_index]
    removed = [before_index[fp] for fp in before_index if fp not in after_index]

    changes = []

    # Added components
    for c in added:
        asset_type = get_asset_type(c)
        detail = {
            'certificate': get_cert_summary,
            'algorithm': lambda c: c.get('name', '?'),
            'related-crypto-material': get_key_summary,
        }.get(asset_type, lambda c: c.get('name', '?'))(c)

        level = 'INFO'
        name = c.get('name', '')
        if asset_type == 'algorithm' and any(name.startswith(w) for w in ('MD5', 'SHA1', 'DES', '3DES', 'RC4')):
            level = 'WARN'
        if asset_type == 'related-crypto-material':
            kt = c.get('cryptoProperties', {}).get('relatedCryptoMaterialProperties', {}).get('type')
            if kt == 'private-key':
                level = 'CRITICAL'

        changes.append({
            'action': 'ADDED',
            'level': level,
            'type': asset_type,
            'detail': detail,
            'location': get_location(c),
        })

    # Removed components
    for c in removed:
        asset_type = get_asset_type(c)
        detail = {
            'certificate': get_cert_summary,
            'algorithm': lambda c: c.get('name', '?'),
            'related-crypto-material': get_key_summary,
        }.get(asset_type, lambda c: c.get('name', '?'))(c)

        changes.append({
            'action': 'REMOVED',
            'level': 'INFO',
            'type': asset_type,
            'detail': detail,
            'location': get_location(c),
        })

    # Count by type
    added_certs = sum(1 for c in added if get_asset_type(c) == 'certificate')
    removed_certs = sum(1 for c in removed if get_asset_type(c) == 'certificate')
    added_algos = sum(1 for c in added if get_asset_type(c) == 'algorithm')
    removed_algos = sum(1 for c in removed if get_asset_type(c) == 'algorithm')
    added_keys = sum(1 for c in added if get_asset_type(c) == 'related-crypto-material')
    removed_keys = sum(1 for c in removed if get_asset_type(c) == 'related-crypto-material')

    return {
        'summary': {
            'added_certs': added_certs,
            'removed_certs': removed_certs,
            'added_algos': added_algos,
            'removed_algos': removed_algos,
            'added_keys': added_keys,
            'removed_keys': removed_keys,
            'total_changes': len(changes),
        },
        'changes': changes,
        # Raw components — preserved so callers can emit standalone CBOMs of the
        # added/removed sets and feed them into cbom_ingest.py with
        # --event-type diff-added / diff-removed.
        '_added_components': added,
        '_removed_components': removed,
    }


def make_subset_cbom(components, source_after, scanner_hint=''):
    """Wrap a list of components in a CycloneDX 1.6 envelope so it can be fed
    into cbom_ingest.py. Inherits scanner identity from the source CBOM
    metadata when present, so downstream ingest sets cbom_scanner correctly.
    """
    import datetime, uuid
    meta_component = {'type': 'application', 'name': scanner_hint or 'cbom-diff', 'version': '1.0.0'}
    src_meta = source_after.get('metadata', {}).get('component', {}) if isinstance(source_after, dict) else {}
    if src_meta.get('name'):
        meta_component = src_meta
    return {
        '$schema': 'https://cyclonedx.org/schema/bom-1.6.schema.json',
        'bomFormat': 'CycloneDX',
        'specVersion': '1.6',
        'serialNumber': 'urn:uuid:' + str(uuid.uuid4()),
        'version': 1,
        'metadata': {
            'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'component': meta_component,
        },
        'components': components,
    }


def main():
    parser = argparse.ArgumentParser(description="Diff two CycloneDX CBOMs")
    parser.add_argument("before", help="Baseline CBOM JSON file")
    parser.add_argument("after", help="New CBOM JSON file")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument(
        "--emit-added",
        help="Write a CBOM 1.6 JSON of just the added components to this path",
    )
    parser.add_argument(
        "--emit-removed",
        help="Write a CBOM 1.6 JSON of just the removed components to this path",
    )
    parser.add_argument(
        "--scanner-hint", default='',
        help="Scanner name to embed in emitted CBOM metadata (cbom_ingest reads this)",
    )
    args = parser.parse_args()

    result = diff_cboms(args.before, args.after)

    # Optional emit hooks fire before stdout printing so they work in any mode.
    if args.emit_added or args.emit_removed:
        with open(args.after) as f:
            after_bom = json.load(f)
        if args.emit_added:
            sub = make_subset_cbom(result['_added_components'], after_bom, args.scanner_hint)
            with open(args.emit_added, 'w') as f:
                json.dump(sub, f, indent=2)
        if args.emit_removed:
            sub = make_subset_cbom(result['_removed_components'], after_bom, args.scanner_hint)
            with open(args.emit_removed, 'w') as f:
                json.dump(sub, f, indent=2)

    if args.json:
        # Strip the bulky raw component lists from --json output to keep it
        # parseable by existing consumers.
        public = {k: v for k, v in result.items() if not k.startswith('_')}
        print(json.dumps(public, indent=2))
    else:
        changes = result['changes']
        s = result['summary']

        if not changes:
            print("  \033[32mNo changes detected.\033[0m")
        else:
            level_order = {'CRITICAL': 0, 'WARN': 1, 'INFO': 2}
            for ch in sorted(changes, key=lambda c: (level_order.get(c['level'], 9), c['action'], c['type'] or '')):
                color = '\033[32m' if ch['action'] == 'ADDED' else '\033[31m'
                prefix = '+' if ch['action'] == 'ADDED' else '-'
                warn = ''
                if ch['level'] == 'WARN':
                    warn = ' \033[33m[WEAK]\033[0m'
                elif ch['level'] == 'CRITICAL':
                    warn = ' \033[31m[CRITICAL]\033[0m'
                print(f"  {color}{prefix}\033[0m [{ch['type']}] {ch['detail']}{warn} \033[90m({ch['location']})\033[0m")

        print()
        print(f"  Summary: +{s['added_certs']}/-{s['removed_certs']} certs"
              f", +{s['added_algos']}/-{s['removed_algos']} algos"
              f", +{s['added_keys']}/-{s['removed_keys']} keys"
              f" ({s['total_changes']} total changes)")

    sys.exit(1 if result['summary']['total_changes'] > 0 else 0)


if __name__ == '__main__':
    main()
