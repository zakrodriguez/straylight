#!/usr/bin/env python3
"""Deduplicate algorithm components in a CycloneDX CBOM.

cbomkit-theia creates one algorithm component per certificate reference.
This script merges duplicates by name+properties, keeping one canonical
component and rewriting all dependency refs.

Usage:
    python3 scripts/cbom-dedup.py cbom-one-tier-*.json
    python3 scripts/cbom-dedup.py input.json -o deduped.json
"""
import json
import sys
import argparse


def dedup_cbom(bom):
    components = bom.get("components", [])
    dependencies = bom.get("dependencies", [])

    # Separate algorithms from everything else
    algos = []
    others = []
    for c in components:
        cp = c.get("cryptoProperties", {})
        if cp.get("assetType") == "algorithm":
            algos.append(c)
        else:
            others.append(c)

    # Group algorithms by a fingerprint (name + all crypto properties).
    # When two scans report the same algorithm at different locations
    # (e.g. ML-DSA-65 served by both observe1:8444 and stepca1:9444), keep
    # one canonical component and union ALL their occurrences into it —
    # otherwise the deduped CBOM loses every location after the first and
    # downstream consumers see one endpoint per algo instead of all of them.
    groups = {}
    ref_map = {}  # old bom-ref -> canonical bom-ref
    for a in algos:
        key = a.get("name", "") + "||" + json.dumps(a.get("cryptoProperties"), sort_keys=True)
        if key not in groups:
            groups[key] = a
        else:
            canon = groups[key]
            existing_locs = {
                o.get("location")
                for o in canon.get("evidence", {}).get("occurrences", [])
            }
            for occ in a.get("evidence", {}).get("occurrences", []):
                if occ.get("location") not in existing_locs:
                    canon.setdefault("evidence", {}).setdefault("occurrences", []).append(occ)
                    existing_locs.add(occ.get("location"))
        ref_map[a["bom-ref"]] = groups[key]["bom-ref"]

    canonical_algos = list(groups.values())

    # Rewrite dependency refs
    deduped_deps = []
    seen_deps = set()
    for dep in dependencies:
        dep["ref"] = ref_map.get(dep["ref"], dep["ref"])
        dep["dependsOn"] = list({
            ref_map.get(r, r) for r in dep.get("dependsOn", [])
        })
        # Deduplicate dependency entries that now have the same ref
        dep_key = dep["ref"]
        if dep_key in seen_deps:
            # Merge dependsOn into existing entry
            for d in deduped_deps:
                if d["ref"] == dep_key:
                    existing = set(d["dependsOn"])
                    existing.update(dep["dependsOn"])
                    d["dependsOn"] = list(existing)
                    break
        else:
            seen_deps.add(dep_key)
            deduped_deps.append(dep)

    # Rewrite signatureAlgorithmRef and subjectPublicKeyRef inside certificates
    # These also point to algorithm/key bom-refs that may have been deduped
    for c in others:
        cp = c.get("cryptoProperties", {})
        cert_props = cp.get("certificateProperties")
        if not cert_props:
            continue
        for ref_field in ("signatureAlgorithmRef", "subjectPublicKeyRef"):
            old_ref = cert_props.get(ref_field)
            if old_ref and old_ref in ref_map:
                cert_props[ref_field] = ref_map[old_ref]

    bom["components"] = others + canonical_algos
    bom["dependencies"] = deduped_deps
    return bom, len(algos), len(canonical_algos)


def main():
    parser = argparse.ArgumentParser(description="Deduplicate CBOM algorithms")
    parser.add_argument("input", help="Input CBOM JSON file")
    parser.add_argument("-o", "--output", help="Output file (default: overwrite input)")
    args = parser.parse_args()

    with open(args.input) as f:
        bom = json.load(f)

    bom, before, after = dedup_cbom(bom)
    removed = before - after

    output = args.output or args.input
    with open(output, "w") as f:
        json.dump(bom, f, indent=2)

    total = len(bom["components"])
    print(f"Algorithms: {before} -> {after} ({removed} duplicates removed)")
    print(f"Components: {total} total")
    print(f"Written to: {output}")


if __name__ == "__main__":
    main()
