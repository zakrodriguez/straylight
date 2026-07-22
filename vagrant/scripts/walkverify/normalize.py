"""Volatile-output normalizers: apply named regex->placeholder rules, and
suggest built-ins that match a captured sample. Applied ONLY to output that is
asserted on (expect/strict) — never silently to the whole capture."""
from __future__ import annotations
import re

# name -> regex pattern for output that legitimately varies run to run.
SUGGESTORS = {
    "latency": r"\b\d+\s*ms\b",
    "serial": r"[Ss]erial\s*[Nn]umber:\s*[0-9A-Fa-f]+",
    "guid": r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    "isotime": r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}",
}

def apply(text: str, normalizers: dict) -> str:
    out = text
    for rule in normalizers.values():
        out = re.sub(rule["pattern"], rule["placeholder"], out)
    return out

def suggest(text: str) -> dict:
    found = {}
    for name, pattern in SUGGESTORS.items():
        if re.search(pattern, text):
            found[name] = {"pattern": pattern, "placeholder": f"<{name.upper()}>"}
    return found
