"""Extract run-scoped bindings from a step's output per its capture rules.

A capture rule is {"name": str, "pattern": str}; the pattern's group 1 is the
captured value. Pure — no I/O. Rules are validated (compile + >=1 group) at
annotate/lint time, so extract may assume compilable patterns."""
from __future__ import annotations
import re

def extract(step_captures, output):
    """Return (bindings, errors). bindings[name] = group(1) for each rule that
    matches; an unmatched rule appends an error and binds nothing."""
    bindings, errors = {}, []
    for cap in step_captures or []:
        m = re.search(cap["pattern"], output)
        if m and m.group(1) is not None:
            bindings[cap["name"]] = m.group(1)
        else:
            errors.append(
                f"capture {cap['name']!r} — pattern /{cap['pattern']}/ "
                f"matched nothing")
    return bindings, errors
