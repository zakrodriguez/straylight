"""Read-only VBoxManage poller: power state + reboot-transition detection."""
from __future__ import annotations
import re
import subprocess

_STATE_RE = re.compile(r'^VMState="([^"]+)"', re.MULTILINE)
_KNOWN = {"running", "poweroff", "paused", "saved", "aborted"}
_ALLOWED_VERBS = {"list", "showvminfo"}

def _default_runner(args):
    if not args or args[0] not in _ALLOWED_VERBS:
        raise ValueError(f"buildmon is observer-only; refusing VBoxManage {args!r}")
    out = subprocess.run(["VBoxManage", *args], capture_output=True, text=True, timeout=15)
    return out.stdout

def parse_showvminfo(text):
    m = _STATE_RE.search(text)
    state = m.group(1) if m else "unknown"
    if state not in _KNOWN:
        state = "unknown"
    return {"vbox": state, "uptime_s": None}

def list_registered(runner=None):
    runner = runner or _default_runner
    text = runner(["list", "vms"])
    out = {}
    for line in text.splitlines():
        m = re.match(r'"([^"]+)"\s+\{([0-9a-fA-F-]+)\}', line)
        if m:
            out[m.group(1)] = m.group(2)
    return out

class VBoxPoller:
    def __init__(self, name_map, runner=None, clock=None):
        self.name_map = name_map
        self.runner = runner or _default_runner
        self.clock = clock

    def poll(self, vm):
        machine = self.name_map.get(vm, vm)
        return parse_showvminfo(self.runner(["showvminfo", machine, "--machinereadable"]))

    def detect_reboot(self, vm, prev_state, new_state):
        return prev_state in {"poweroff", "saved", "aborted"} and new_state == "running"
