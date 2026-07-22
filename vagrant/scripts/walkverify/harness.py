"""Orchestrate lint (static) and check (live-replay + gate) over a lab and its
companion. verify() (interactive capture) lives in __main__ — it needs a live
build and human approval, so it is not part of the pure-testable core."""
from __future__ import annotations
import annotate
import capture
import companion as companion_mod
import gate

def _companion_step(comp, step_id):
    for s in comp.get("steps", []):
        if s["step"] == step_id:
            return s
    return None

def _preamble_cmd(steps, host):
    for s in steps:
        if s.get("preamble") and s["host"] == host:
            return s["command"]
    return ""

def _all_capture_names(steps):
    names = set()
    for s in steps:
        for cap in s.get("captures", []):
            names.add(cap["name"])
    return names


def unresolved_refs(steps, params, runner):
    """Yield (step_id, var_name, kind). kind is 'forward' when var_name is
    captured only by a step at or after this one, else 'undefined'. Order-aware:
    a var captured by a strictly-earlier step is considered resolved."""
    declared = set()
    all_caps = _all_capture_names(steps)
    for s in steps:
        preamble = _preamble_cmd(steps, s["host"])
        for name in runner.unresolved(s, params, preamble, declared):
            kind = "forward" if (name in all_caps and name not in declared) else "undefined"
            yield (s["step"], name, kind)
        for cap in s.get("captures", []):
            declared.add(cap["name"])


def lint(md_text, companion_dict, runner):
    steps = annotate.parse_lab(md_text)
    problems = list(companion_mod.validate(companion_dict, steps))
    params = companion_dict.get("parameters", {})
    param_names = set(params)
    for step_id, name, kind in unresolved_refs(steps, params, runner):
        if kind == "forward":
            problems.append(f"step {step_id!r} references ${name} captured only "
                            f"by this or a later step")
        else:
            problems.append(f"step {step_id!r} references undefined ${name} "
                            f"(add to parameters)")
    for s in steps:
        for cap in s.get("captures", []):
            if cap["name"] in param_names:
                problems.append(f"step {s['step']!r} capture {cap['name']!r} "
                                f"shadows a parameter")
    return problems

def _run_steps(steps, params, runner, stop_on_error=False):
    """Execute steps in document order, threading run-scoped capture bindings
    forward. Returns (records, final_bindings). One record per step:
    {step, host, command, rc, stdout, captures, capture_errors, run_error}.
    When stop_on_error is True, a runtime exception on a step halts execution
    of any later steps (used by verify, to avoid running live commands after
    a known cascade); when False (default, used by check), execution
    continues past the failure so a full pass/fail map is produced."""
    bindings = {}
    records = []
    for s in steps:
        preamble = _preamble_cmd(steps, s["host"])
        rec = {"step": s["step"], "host": s["host"], "command": s["command"],
               "rc": None, "stdout": "", "captures": {}, "capture_errors": [],
               "run_error": None}
        try:
            out = runner.run(s, params, preamble, bindings)
        except Exception as exc:
            rec["run_error"] = str(exc)
            records.append(rec)
            if stop_on_error:
                break
            continue
        rec["rc"], rec["stdout"] = out["rc"], out["stdout"]
        caps, errs = capture.extract(s.get("captures", []), out["stdout"])
        bindings.update(caps)
        rec["captures"], rec["capture_errors"] = caps, errs
        records.append(rec)
    return records, bindings

def check(md_text, companion_dict, runner):
    steps = annotate.parse_lab(md_text)
    params = companion_dict.get("parameters", {})
    norms = companion_dict.get("normalizers", {})
    step_by_id = {s["step"]: s for s in steps}
    records, _ = _run_steps(steps, params, runner)
    results = []
    for rec in records:
        if rec["run_error"] is not None:
            results.append({"step": rec["step"], "passed": False,
                            "reasons": [f"run error: {rec['run_error']}"]})
            continue
        s = step_by_id[rec["step"]]
        golden = _companion_step(companion_dict, rec["step"])
        merged = dict(s)
        if golden:
            merged["expects"] = golden.get("expect", s["expects"])
            merged["rc"] = golden.get("rc", s["rc"])
            merged["strict"] = golden.get("strict", s["strict"])
        g = gate.evaluate(merged, {"stdout": rec["stdout"], "rc": rec["rc"]}, norms,
                          golden={"captured": golden.get("captured", "")} if golden else None)
        reasons = list(g["reasons"]) + list(rec["capture_errors"])
        results.append({"step": rec["step"],
                        "passed": g["passed"] and not rec["capture_errors"],
                        "reasons": reasons})
    return {"results": results, "passed": all(r["passed"] for r in results)}
