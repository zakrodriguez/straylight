"""walkverify CLI: lint (static) | verify (capture golden) | check (replay+gate)."""
from __future__ import annotations
import argparse
import os
import sys

# Sibling modules (annotate, companion, harness, normalize, runner) use bare
# imports of each other. When invoked as `python3 -m walkverify` from the
# package's parent directory, that parent (not this package dir) is on
# sys.path, so the package dir must be added explicitly for those bare
# imports to resolve — mirrors how tests/test_harness.py bootstraps itself.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import annotate
import companion as companion_mod
import harness
import normalize
from runner import StepRunner

# Repo root is a fixed 4 levels above this file:
# <repo>/vagrant/scripts/walkverify/__main__.py
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
_DEFAULT_VAGRANT_ROOT = os.path.join(_REPO_ROOT, "vagrant")

def _default_companion(lab_path):
    # Companions live in one place regardless of where the lab file is; only
    # the lab's basename varies. Anchored on _REPO_ROOT (fixed), never on the
    # user-supplied lab_path's directory.
    base = os.path.splitext(os.path.basename(lab_path))[0]
    return os.path.join(_REPO_ROOT, "docs", "walkthroughs", "walkverify",
                        f"{base}.golden.yml")

def _read(path):
    with open(path) as fh:
        return fh.read()

def cmd_lint(args):
    md = _read(args.lab)
    comp_path = args.companion or _default_companion(args.lab)
    comp = companion_mod.load(comp_path) if os.path.isfile(comp_path) else {}
    runner = StepRunner(comp.get("profile", args.profile), args.vagrant_root,
                        exec_fn=lambda *a: (0, ""))
    problems = harness.lint(md, comp, runner)
    for p in problems:
        print(f"LINT {p}", file=sys.stderr)
    return 1 if problems else 0

def cmd_check(args):
    md = _read(args.lab)
    comp = companion_mod.load(args.companion or _default_companion(args.lab))
    runner = StepRunner(comp.get("profile", args.profile), args.vagrant_root)
    out = harness.check(md, comp, runner)
    for r in out["results"]:
        mark = "PASS" if r["passed"] else "FAIL"
        print(f"  {mark}  {r['step']}")
        for reason in r["reasons"]:
            print(f"        - {reason}")
    print(f"{'OK' if out['passed'] else 'FAILED'} "
          f"({sum(r['passed'] for r in out['results'])}/{len(out['results'])})")
    return 0 if out["passed"] else 1

def cmd_verify(args):
    md = _read(args.lab)
    comp_path = args.companion or _default_companion(args.lab)
    comp = companion_mod.load(comp_path) if os.path.isfile(comp_path) else {}
    profile = comp.get("profile") or args.profile
    if not profile:
        print("verify: --profile required (or set in existing companion)", file=sys.stderr)
        return 2
    runner = StepRunner(profile, args.vagrant_root)
    steps = annotate.parse_lab(md)
    params = comp.get("parameters", {})
    # fail-loud on any statically-unresolvable reference before touching a VM
    blocking = []
    for step_id, name, kind in harness.unresolved_refs(steps, params, runner):
        if kind == "forward":
            blocking.append(f"step {step_id!r} references ${name} captured only by a later step")
        else:
            blocking.append(f"step {step_id!r} needs parameter ${name}")
    if blocking:
        for b in blocking:
            print(f"verify: {b}", file=sys.stderr)
        print("verify: resolve these (add a parameter, or capture earlier) and re-run",
              file=sys.stderr)
        return 2
    records, _ = harness._run_steps(steps, params, runner, stop_on_error=True)
    step_by_id = {s["step"]: s for s in steps}
    captured_steps, all_norms = [], dict(comp.get("normalizers", {}))
    for rec in records:
        if rec["run_error"] is not None:
            print(f"verify: step {rec['step']!r} failed to run: {rec['run_error']}",
                  file=sys.stderr)
            return 1
        print(f"\n=== {rec['step']} on {rec['host']} (rc={rec['rc']}) ===")
        print(rec["stdout"])
        for cname, cval in rec["captures"].items():
            print(f"    capture {cname} -> {cval}")
        for cerr in rec["capture_errors"]:
            print(f"    capture FAILED: {cerr}", file=sys.stderr)
        for name, rule in normalize.suggest(rec["stdout"]).items():
            all_norms.setdefault(name, rule)
        s = step_by_id[rec["step"]]
        captured_steps.append({"step": s["step"], "host": s["host"],
                               "command": s["command"], "rc": s["rc"],
                               "expect": s["expects"], "strict": s["strict"],
                               "captured": normalize.apply(rec["stdout"], all_norms)})
    if all_norms:
        print("\nsuggested normalizers:", ", ".join(all_norms))
    ans = input("\napprove and write golden? [y/N] ").strip().lower()
    if ans != "y":
        print("verify: not approved; nothing written")
        return 1
    out = {"lab": os.path.splitext(os.path.basename(args.lab))[0],
           "profile": profile, "parameters": params,
           "normalizers": all_norms, "steps": captured_steps}
    os.makedirs(os.path.dirname(comp_path), exist_ok=True)
    companion_mod.dump(out, comp_path)
    print(f"verify: wrote {comp_path}")
    return 0

def main(argv=None):
    ap = argparse.ArgumentParser(prog="walkverify")
    ap.add_argument("--vagrant-root", default=_DEFAULT_VAGRANT_ROOT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("lint", "verify", "check"):
        s = sub.add_parser(name)
        s.add_argument("lab")
        s.add_argument("--companion")
        s.add_argument("--profile")
    args = ap.parse_args(argv)
    return {"lint": cmd_lint, "verify": cmd_verify, "check": cmd_check}[args.cmd](args)

if __name__ == "__main__":
    sys.exit(main())
