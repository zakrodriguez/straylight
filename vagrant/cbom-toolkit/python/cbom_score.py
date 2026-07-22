#!/usr/bin/env python3
"""PQC readiness scoring per VM from a CycloneDX CBOM.

Usage:
    python3 cbom_score.py cbom-one-tier-deduped.json
    python3 cbom_score.py cbom.json --json
"""
import json
import re
import sys
import argparse
from collections import defaultdict


# Classifier lives in pqc_classify so cbom_score.py and cbom_ingest.py
# can't drift apart again (bug #14 in pqc-remediation-progress).
from pqc_classify import classify as get_pqc_class  # noqa: E402


def get_grade(safe_pct):
    if safe_pct >= 80:
        return 'GREEN'
    if safe_pct >= 50:
        return 'AMBER'
    return 'RED'


def get_vm_name(component):
    for occ in component.get('evidence', {}).get('occurrences', []):
        loc = occ.get('location', '')
        m = re.match(r'^([^/]+)/', loc)
        if m:
            return m.group(1)
    return '?'


def score_cbom(bom_path):
    with open(bom_path) as f:
        bom = json.load(f)

    # Build bom-ref index for resolving certificate refs
    ref_index = {c['bom-ref']: c for c in bom.get('components', []) if 'bom-ref' in c}

    vm_data = defaultdict(lambda: {
        'total': 0, 'vulnerable': 0, 'safe': 0, 'weak': 0, 'unknown': 0,
        'migration': set(),
    })

    for c in bom.get('components', []):
        name = c.get('name', '')
        if not name:
            continue
        cp = c.get('cryptoProperties', {})
        asset_type = cp.get('assetType')
        if asset_type not in ('algorithm', 'related-crypto-material', 'certificate'):
            continue

        # For certificates, classify by signature algorithm, not cert name
        if asset_type == 'certificate':
            sig_ref = cp.get('certificateProperties', {}).get('signatureAlgorithmRef')
            if sig_ref and sig_ref in ref_index:
                sig_name = ref_index[sig_ref].get('name', '')
                pqc_class = get_pqc_class(sig_name)
                display_name = f"{name} (signed with {sig_name})"
            else:
                pqc_class = 'unknown'
                display_name = name
        else:
            pqc_class = get_pqc_class(name)
            display_name = name

        vm_name = get_vm_name(c)

        vm_data[vm_name]['total'] += 1
        if pqc_class == 'quantum-vulnerable':
            vm_data[vm_name]['vulnerable'] += 1
            vm_data[vm_name]['migration'].add(f"{display_name} ({asset_type})")
        elif pqc_class == 'quantum-safe':
            vm_data[vm_name]['safe'] += 1
        elif pqc_class == 'weak-classical':
            vm_data[vm_name]['weak'] += 1
        else:
            vm_data[vm_name]['unknown'] += 1

    # Build scorecards
    scorecards = []
    for vm in sorted(vm_data.keys()):
        d = vm_data[vm]
        classified = d['total'] - d['unknown']
        safe_pct = round(d['safe'] / classified * 100, 1) if classified > 0 else 0
        vuln_pct = round(d['vulnerable'] / classified * 100, 1) if classified > 0 else 0
        weak_pct = round(d['weak'] / classified * 100, 1) if classified > 0 else 0

        scorecards.append({
            'vm': vm,
            'total': d['total'],
            'vulnerable': d['vulnerable'],
            'safe': d['safe'],
            'weak': d['weak'],
            'unknown': d['unknown'],
            'safe_pct': safe_pct,
            'vuln_pct': vuln_pct,
            'weak_pct': weak_pct,
            'grade': get_grade(safe_pct),
            'migration': sorted(d['migration']),
        })

    # Lab-wide
    lab_total = sum(d['total'] for d in vm_data.values())
    lab_vuln = sum(d['vulnerable'] for d in vm_data.values())
    lab_safe = sum(d['safe'] for d in vm_data.values())
    lab_weak = sum(d['weak'] for d in vm_data.values())
    lab_unknown = sum(d['unknown'] for d in vm_data.values())
    lab_classified = lab_total - lab_unknown
    lab_safe_pct = round(lab_safe / lab_classified * 100, 1) if lab_classified > 0 else 0

    return {
        'file': bom_path,
        'lab_summary': {
            'total': lab_total,
            'vulnerable': lab_vuln,
            'safe': lab_safe,
            'weak': lab_weak,
            'unknown': lab_unknown,
            'safe_pct': lab_safe_pct,
            'grade': get_grade(lab_safe_pct),
        },
        'vms': scorecards,
    }


def main():
    parser = argparse.ArgumentParser(description="PQC readiness scoring per VM")
    parser.add_argument("input", help="CBOM JSON file")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    result = score_cbom(args.input)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        grade_colors = {'GREEN': '\033[32m', 'AMBER': '\033[33m', 'RED': '\033[31m'}
        reset = '\033[0m'
        dim = '\033[90m'
        cyan = '\033[36m'

        print()
        print(f"  {cyan}PQC Readiness Scorecard{reset}")
        print(f"  {cyan}{'═' * 23}{reset}")
        print()

        # Table header
        fmt = "  {:<12} {:>6} {:>6} {:>6} {:>6} {:>8} {:>6}"
        print(fmt.format('VM', 'Total', 'Vuln', 'Safe', 'Weak', 'Safe %', 'Grade'))
        print(f"  {'-' * 58}")

        for sc in result['vms']:
            gc = grade_colors.get(sc['grade'], '')
            print(f"  {sc['vm']:<12} {sc['total']:>6} {sc['vulnerable']:>6} "
                  f"{sc['safe']:>6} {sc['weak']:>6} {sc['safe_pct']:>7}% "
                  f"{gc}{sc['grade']:>6}{reset}")

        print(f"  {'-' * 58}")
        lab = result['lab_summary']
        gc = grade_colors.get(lab['grade'], '')
        print(f"  {'LAB TOTAL':<12} {lab['total']:>6} {lab['vulnerable']:>6} "
              f"{lab['safe']:>6} {lab['weak']:>6} {lab['safe_pct']:>7}% "
              f"{gc}{lab['grade']:>6}{reset}")

        # Migration targets
        print()
        print(f"  {cyan}Migration Targets{reset}")
        print(f"  {cyan}{'─' * 17}{reset}")
        for sc in result['vms']:
            if not sc['migration']:
                continue
            print(f"  \033[33m{sc['vm']}:\033[0m")
            for m in sc['migration']:
                print(f"    {dim}→ {m}{reset}")
        print()

    sys.exit(0)


if __name__ == '__main__':
    main()
