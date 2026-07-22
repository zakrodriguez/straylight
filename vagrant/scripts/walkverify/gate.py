"""Decide whether a step's captured output passes: rc + every expect regex,
plus optional strict full-diff. Normalizers apply only here (asserted output)."""
from __future__ import annotations
import re
import normalize

def evaluate(step, captured, normalizers, golden=None):
    reasons = []
    norm_out = normalize.apply(captured.get("stdout", ""), normalizers)
    if captured.get("rc") != step["rc"]:
        reasons.append(f"exit code {captured.get('rc')} != expected {step['rc']}")
    for pattern in step["expects"]:
        if not re.search(pattern, norm_out):
            reasons.append(f"expect /{pattern}/ did not match output")
    if step.get("strict") and golden is not None:
        norm_golden = normalize.apply(golden.get("captured", ""), normalizers)
        if norm_out.strip() != norm_golden.strip():
            reasons.append("strict full-output diff against golden")
    return {"passed": not reasons, "reasons": reasons}
