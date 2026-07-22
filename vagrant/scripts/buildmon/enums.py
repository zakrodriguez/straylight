"""Feed enum vocabularies (exact strings — the machine contract)."""
from __future__ import annotations

PHASES = frozenset({"creating", "dc1-provision", "parallel-provision", "done", "failed"})
VM_STATES = frozenset({"pending", "creating", "booting", "provisioning",
                       "rebooting", "waiting-dep", "done", "failed", "hung"})
VBOX_STATES = frozenset({"running", "poweroff", "paused", "saved", "aborted", "unknown"})
EVENT_KINDS = frozenset({"phase", "state", "task", "reboot", "waiting-dep",
                         "hung", "done", "monitor"})

_SETS = {"phase": PHASES, "state": VM_STATES, "vbox": VBOX_STATES, "event": EVENT_KINDS}

def is_valid(kind: str, value: str) -> bool:
    return value in _SETS.get(kind, frozenset())
