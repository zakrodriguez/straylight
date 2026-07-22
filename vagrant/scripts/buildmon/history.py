"""Cross-run provision-attempt tracking.

Pure filesystem functions — no collector/model state. Given a live build's
logdir and profile, count how many prior same-profile runs each VM already
failed or was interrupted in, stopping at the VM's most recent success or a
manual reset cutoff.
"""
from __future__ import annotations
import json
import os
import re
import topology

LOGDIR_RE = re.compile(r"^\d{8}-\d{6}$")  # YYYYMMDD-HHMMSS
_MARKER_DIR = ".buildmon"


def reset_marker_path(logs_root, profile):
    return os.path.join(logs_root, _MARKER_DIR, f"attempts-reset-{profile}")


def read_reset_cutoff(logs_root, profile):
    try:
        with open(reset_marker_path(logs_root, profile)) as fh:
            val = fh.read().strip()
        return val or None
    except OSError:
        return None


def write_reset_marker(logs_root, profile, stamp):
    path = reset_marker_path(logs_root, profile)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(stamp + "\n")
    os.replace(tmp, path)
    return path


def sibling_logdirs(logdir, cap=30):
    logdir = os.path.normpath(logdir)
    parent = os.path.dirname(logdir)
    base = os.path.basename(logdir)
    try:
        entries = os.listdir(parent)
    except OSError:
        return []
    dirs = [e for e in entries
            if LOGDIR_RE.match(e) and e < base
            and os.path.isdir(os.path.join(parent, e))]
    dirs.sort(reverse=True)  # newest first
    return dirs[:cap]


_TASK_RE = re.compile(r"^TASK \[", re.M)
_RECAP_RE = re.compile(r"^(\S+)\s*:\s*ok=\d+.*?unreachable=(\d+).*?failed=(\d+)", re.M)
_ANSIBLE_FAILED_RE = re.compile(r"Ansible failed to complete", re.M)


def _classify_from_status_json(logdir_path, vm):
    """Conclusive state from this logdir's own feed, or None."""
    try:
        with open(os.path.join(logdir_path, "buildmon", "status.json")) as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            return None
        state = (data.get("vms", {}).get(vm) or {}).get("state")
    except (OSError, ValueError):
        return None
    if state == "done":
        return "success"
    if state == "failed":
        return "failed"
    return None  # inconclusive → fall through to log parse


def _classify_from_log(logdir_path, vm):
    path = os.path.join(logdir_path, f"{vm}.log")
    try:
        with open(path, errors="replace") as fh:
            text = fh.read()
    except OSError:
        return "none"
    recaps = _RECAP_RE.findall(text)
    if recaps:
        # any recap line with unreachable>0 or failed>0 → failed, else success
        for _host, unreachable, failed in recaps:
            if int(unreachable) or int(failed):
                return "failed"
        return "success"
    if _ANSIBLE_FAILED_RE.search(text):
        return "failed"
    if _TASK_RE.search(text):
        return "interrupted"
    return "none"


def classify_run(logdir_path, vm):
    shortcut = _classify_from_status_json(logdir_path, vm)
    if shortcut is not None:
        return shortcut
    return _classify_from_log(logdir_path, vm)


def _sibling_profile(logdir_path, profiles_dir):
    """Profile a historical logdir belongs to: its own feed's recorded
    profile if present, else inferred from its VM stems."""
    try:
        with open(os.path.join(logdir_path, "buildmon", "status.json")) as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            return topology.infer_profile(logdir_path, profiles_dir)
        p = data.get("build", {}).get("profile")
        if p and p != "unknown":
            return p
    except (OSError, ValueError):
        pass
    return topology.infer_profile(logdir_path, profiles_dir)


def scan_attempts(logdir, profile, profiles_dir=None, cap=30):
    logdir = os.path.normpath(logdir)
    logs_root = os.path.dirname(logdir)
    vms = topology.logdir_vm_stems(logdir)
    cutoff = read_reset_cutoff(logs_root, profile) if profile else None
    siblings = sibling_logdirs(logdir, cap=cap)
    if cutoff:
        siblings = [s for s in siblings if s > cutoff]

    # Only walk siblings that belong to this profile. Resolve each once.
    same_profile = []
    for s in siblings:
        sp = os.path.join(logs_root, s)
        if profile and _sibling_profile(sp, profiles_dir) == profile:
            same_profile.append(sp)

    result = {}
    for vm in vms:
        failed = interrupted = 0
        for sp in same_profile:  # already newest-first
            outcome = classify_run(sp, vm)
            if outcome == "success":
                break
            elif outcome == "failed":
                failed += 1
            elif outcome == "interrupted":
                interrupted += 1
            # "none" → VM wasn't provisioned that run; ignore, keep walking
        result[vm] = {"attempt": 1 + failed + interrupted,
                      "prior": {"failed": failed, "interrupted": interrupted}}
    return result
