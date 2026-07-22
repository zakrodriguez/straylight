"""Interpret raw signals into per-VM lifecycle states + build phase + dep-wait."""
from __future__ import annotations
import re

WAIT_DEP_PATTERNS = [
    (re.compile(r"Wait for Root CA cert", re.I), "ca1 root cert"),
    (re.compile(r"Wait .*Root CA", re.I), "ca1 root cert"),
    (re.compile(r"Wait .*domain", re.I), "domain join"),
]
_REBOOT_TASK_RE = re.compile(r"reboot|restart", re.I)
REBOOT_STALL_MIN_S = 30  # a reboot-task log must be quiet this long before we call it rebooting
_RUNNING_ISH = {"booting", "provisioning", "rebooting", "waiting-dep"}

def detect_waiting_on(task_name):
    if not task_name:
        return None
    for rx, label in WAIT_DEP_PATTERNS:
        if rx.search(task_name):
            return label
    return None

def derive_vm_state(prev_state, log, vbox, pid_alive, reboot, stall_s, hang_threshold_s):
    if not log.exists:
        return "booting" if vbox == "running" else (prev_state if prev_state != "pending" else "pending")
    if log.fatal_finish or (log.recap_failed and log.recap_failed >= 1):
        if log.fatal_finish and stall_s >= hang_threshold_s:
            return "hung"
        return "failed"
    if vbox in ("poweroff", "saved") and pid_alive:
        return "rebooting"
    # Warm reboot: VBox can't see a guest-OS restart (VMState stays
    # 'running'), but a reboot-pattern task whose log has gone quiet is one.
    # Exempt from hang up to the ceiling; past it, normal rules resume.
    if (log.task_name and _REBOOT_TASK_RE.search(log.task_name)
            and pid_alive and vbox == "running"
            and REBOOT_STALL_MIN_S <= stall_s < hang_threshold_s):
        return "rebooting"
    # Done beats waiting-dep: a play that ENDS cleanly while its last-seen
    # task was a "Wait for ..." dependency gate would otherwise read
    # waiting-dep forever (the recap is the stronger signal).
    if log.recap_failed == 0 and pid_alive is not True:
        return "done"
    if detect_waiting_on(log.task_name):
        return "waiting-dep"
    return "provisioning"

def derive_build_phase(vm_states, dc1_present):
    states = list(vm_states.values())
    if states and all(s == "done" for s in states):
        return "done"
    running = [s for s in states if s in _RUNNING_ISH]
    failed_or_hung = [s for s in states if s in ("failed", "hung")]
    if failed_or_hung and not running:
        return "failed"
    non_dc1_active = any(vm != "dc1" and st in ("provisioning", "rebooting", "waiting-dep", "done")
                         for vm, st in vm_states.items())
    if sum(1 for s in states if s == "provisioning") >= 2 or non_dc1_active:
        return "parallel-provision"
    if dc1_present and vm_states.get("dc1") in ("provisioning", "rebooting", "waiting-dep"):
        return "dc1-provision"
    return "creating"
