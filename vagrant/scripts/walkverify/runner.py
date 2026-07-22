"""Assemble and execute a step's remote script on its host. Transport type
(winrm/ssh) comes from buildmon's creds.resolve; execution shells to vagrant."""
from __future__ import annotations
import os
import re
import subprocess
import sys

# import creds.resolve from the sibling buildmon package
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "buildmon"))
import creds  # noqa: E402

class RunnerError(Exception):
    pass

LOCAL_HOST = "lab"

# $Name references, excluding $env:... and automatic $_
_VAR_RE = re.compile(r"(?<![\w:])\$(?!env:)([A-Za-z_]\w*)")
# An ASSIGNMENT defines a var: `$Name =` (but not `==` comparison, not $env:).
_ASSIGN_RE = re.compile(r"(?<![\w:])\$(?!env:)([A-Za-z_]\w*)\s*=(?!=)")

# PowerShell automatic / constant variables — always valid, never a lab param.
_PS_AUTOMATIC = frozenset({
    "_", "psitem", "args", "input", "this", "true", "false", "null",
    "matches", "error", "foreach", "switch", "pscmdlet", "host", "pwd",
    "home", "pshome", "lastexitcode",
})

def _assign(name, value):
    # PowerShell single-quoted literal: no $-expansion, backslashes stay
    # literal (right for CA config strings like ISSUECA...\YOURLAB-Issuing-CA);
    # embedded single quotes escaped by doubling. Prevents injection/breakage.
    escaped = value.replace("'", "''")
    return f"${name} = '{escaped}'"

class StepRunner:
    def __init__(self, profile, vagrant_root, exec_fn=None, resolver=None):
        self.profile = profile
        self.vagrant_root = vagrant_root
        self.exec_fn = exec_fn or self._default_exec
        self.resolver = resolver or creds.resolve

    def _default_exec(self, transport, host, script):
        if transport == "local":
            argv = ["bash", "-c", script]
        elif transport == "winrm":
            argv = ["vagrant", "winrm", host, "-c", script]
        else:
            argv = ["vagrant", "ssh", host, "-c", script]
        p = subprocess.run(argv, capture_output=True, text=True, timeout=300,
                           cwd=self.vagrant_root)
        # Combine both channels (spec: stdout+stderr), not pick one.
        out = (p.stdout or "") + (p.stderr or "")
        return (p.returncode, out)

    def _defined_names(self, parameters, preamble_cmd):
        names = set(parameters or {})
        # only ASSIGNMENTS in the preamble define a var, not mere references
        for m in _ASSIGN_RE.finditer(preamble_cmd or ""):
            names.add(m.group(1))
        return names

    def assemble(self, step, parameters, preamble_cmd, bindings=None):
        # Local host-side bash steps are self-contained: no PowerShell
        # parameter/preamble/binding injection.
        if step["host"] == LOCAL_HOST:
            return step["command"]
        merged = dict(parameters or {})
        merged.update(bindings or {})   # runtime capture bindings win on collision
        parts = [_assign(k, v) for k, v in merged.items()]
        if preamble_cmd and not step.get("preamble"):
            parts.append(preamble_cmd)
        parts.append(step["command"])
        return "\n".join(parts)

    def unresolved(self, step, parameters, preamble_cmd, captured_names=None):
        defined = self._defined_names(parameters, preamble_cmd)
        defined |= set(captured_names or [])
        # a var assigned earlier within THIS step's own script is defined at
        # runtime (previously only credited for preamble steps -> false
        # positives on ordinary multi-line steps).
        for m in _ASSIGN_RE.finditer(step["command"]):
            defined.add(m.group(1))
        missing, seen = [], set()
        for m in _VAR_RE.finditer(step["command"]):
            name = m.group(1)
            if (name not in defined and name not in seen
                    and name.lower() not in _PS_AUTOMATIC):
                missing.append(name)
                seen.add(name)
        return missing

    def run(self, step, parameters, preamble_cmd, bindings=None):
        script = self.assemble(step, parameters, preamble_cmd, bindings)
        if step["host"] == LOCAL_HOST:
            rc, stdout = self.exec_fn("local", step["host"], script)
            return {"stdout": stdout, "rc": rc}
        d = self.resolver(step["host"], self.profile, self.vagrant_root)
        if not d.get("available"):
            raise RunnerError(
                f"host {step['host']!r} unresolvable: {d.get('reason')}")
        rc, stdout = self.exec_fn(d["transport"], step["host"], script)
        return {"stdout": stdout, "rc": rc}
