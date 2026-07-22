"""The only walkverify module that touches YAML. Load/dump/validate the
per-lab <lab>.golden.yml companion. PyYAML is guaranteed by the ansible
install on the lab host."""
from __future__ import annotations
import yaml

def load(path):
    with open(path) as fh:
        return yaml.safe_load(fh) or {}

def dump(companion, path):
    with open(path, "w") as fh:
        yaml.safe_dump(companion, fh, default_flow_style=False, sort_keys=False)

def validate(companion, steps):
    problems = []
    for key in ("lab", "profile", "steps"):
        if key not in companion:
            problems.append(f"companion missing required key: {key}")
    if "parameters" in companion and not isinstance(companion["parameters"], dict):
        problems.append("parameters must be a mapping")
    norms = companion.get("normalizers")
    if norms is not None and not isinstance(norms, dict):
        problems.append("normalizers must be a mapping")
    else:
        for name, rule in (norms or {}).items():
            if not isinstance(rule, dict) or "pattern" not in rule or "placeholder" not in rule:
                problems.append(f"normalizer {name!r} needs pattern + placeholder")
    annotated = {s["step"] for s in steps}
    companion_steps = {s["step"] for s in companion.get("steps", [])}
    for missing in sorted(annotated - companion_steps):
        problems.append(f"annotated step {missing!r} has no companion entry")
    for orphan in sorted(companion_steps - annotated):
        problems.append(f"companion step {orphan!r} not present in the lab")
    return problems
