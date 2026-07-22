"""Parse @verify sentinels + the fenced block each precedes into Step dicts."""
from __future__ import annotations
import re

class AnnotationError(Exception):
    pass

_SENTINEL_RE = re.compile(r"^\s*<!--\s*@verify\s+(.*?)\s*-->\s*$")
_FENCE_RE = re.compile(r"^\s*```")
# token = key=value; value may be NAME:/regex/ (capture), /regex/ (expect), or a bareword
_TOKEN_RE = re.compile(r"(\w+)=(\w+:/[^/]*/|/[^/]*/|\S+)")
_KNOWN = {"host", "step", "expect", "rc", "strict", "preamble", "capture"}

_CAPTURE_RE = re.compile(r"^([A-Za-z_]\w*):/(.*)/$")

def _parse_sentinel(body: str) -> dict:
    fields = {"expects": [], "rc": 0, "strict": False, "preamble": False,
              "host": None, "step": None, "captures": []}
    for m in _TOKEN_RE.finditer(body):
        key, val = m.group(1), m.group(2)
        if key not in _KNOWN:
            raise AnnotationError(f"unknown @verify key: {key!r}")
        if key == "expect":
            if not (val.startswith("/") and val.endswith("/")):
                raise AnnotationError(f"expect must be /regex/, got {val!r}")
            fields["expects"].append(val[1:-1])
        elif key == "rc":
            try:
                fields["rc"] = int(val)
            except ValueError:
                raise AnnotationError(f"rc must be an integer, got {val!r}")
        elif key in ("strict", "preamble"):
            if val.lower() not in ("true", "false"):
                raise AnnotationError(f"{key} must be true or false, got {val!r}")
            fields[key] = (val.lower() == "true")
        elif key == "capture":
            cm = _CAPTURE_RE.match(val)
            if not cm:
                raise AnnotationError(
                    f"capture must be NAME:/regex/, got {val!r}")
            name, pattern = cm.group(1), cm.group(2)
            try:
                compiled = re.compile(pattern)
            except re.error as exc:
                raise AnnotationError(
                    f"capture {name!r} regex does not compile: {exc}")
            if compiled.groups < 1:
                raise AnnotationError(
                    f"capture {name!r} regex needs a capturing group: /{pattern}/")
            if any(c["name"] == name for c in fields["captures"]):
                raise AnnotationError(f"duplicate capture name in step: {name!r}")
            fields["captures"].append({"name": name, "pattern": pattern})
        else:
            fields[key] = val
    if not fields["host"]:
        raise AnnotationError("@verify requires host=")
    if not fields["step"]:
        raise AnnotationError("@verify requires step=")
    return fields

def _fence_body(lines, start):
    """Return (command_text, index_after_closing_fence) for the fence opening
    at lines[start], or raise if it never closes."""
    body = []
    i = start + 1
    while i < len(lines):
        if _FENCE_RE.match(lines[i]):
            return "\n".join(body).strip(), i + 1
        body.append(lines[i])
        i += 1
    raise AnnotationError("code fence opened but never closed")

def parse_lab(md_text: str) -> list:
    lines = md_text.splitlines()
    steps, seen = [], set()
    i = 0
    while i < len(lines):
        m = _SENTINEL_RE.match(lines[i])
        if not m:
            i += 1
            continue
        fields = _parse_sentinel(m.group(1))
        # the very next non-blank line must open a fence
        j = i + 1
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        if j >= len(lines) or not _FENCE_RE.match(lines[j]):
            raise AnnotationError(
                f"@verify step={fields['step']!r} not followed by a code fence")
        command, after = _fence_body(lines, j)
        if fields["step"] in seen:
            raise AnnotationError(f"duplicate step id: {fields['step']!r}")
        seen.add(fields["step"])
        steps.append({"step": fields["step"], "host": fields["host"],
                      "command": command, "expects": fields["expects"],
                      "rc": fields["rc"], "strict": fields["strict"],
                      "preamble": fields["preamble"],
                      "captures": fields["captures"]})
        i = after
    return steps
