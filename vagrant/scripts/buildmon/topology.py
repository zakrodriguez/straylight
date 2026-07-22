"""Resolve the VM set/order/roles for a build from profile | logdir | VBox."""
from __future__ import annotations
import os
import re

ROLE_HINTS = {
    "dc1": "domain_controller", "ca1": "subordinate_ca", "rootca": "root_ca",
    "issueca": "subordinate_ca", "web1": "web_server", "manage1": "management",
    "ejbca1": "ejbca", "scanner1": "scanner", "stepca1": "stepca",
    "acme1": "acme_client", "observe1": "observability",
}
_EXCLUDE_SUFFIX = ("-create.log", "-snap.log", "-rebuild.log")
_CREATE_SUFFIX = "-create.log"
_NON_VM_STEMS = {"ansible", "validate"}

def _order(vms):
    vms = list(dict.fromkeys(vms))          # de-dupe, keep order
    if "dc1" in vms:
        vms.remove("dc1")
        vms.insert(0, "dc1")
    return [(v, ROLE_HINTS.get(v), i) for i, v in enumerate(vms)]

def _from_profile_yaml(path):
    vms = []
    in_components = False
    with open(path) as fh:
        for line in fh:
            if re.match(r"^\s*components\s*:", line):
                in_components = True
                continue
            if in_components:
                m = re.match(r"^\s*-\s*([A-Za-z0-9_-]+)\s*(?:#.*)?$", line)
                if m:
                    vms.append(m.group(1))
                elif line.strip() and not line.startswith((" ", "-", "\t")):
                    break
    return vms

def logdir_vm_stems(logdir):
    """VM stems present in a build logdir: provision logs (`<vm>.log`) first,
    then create-only VMs (`<vm>-create.log` — written for every VM as soon as
    up.sh Phase 1 starts, so the full VM set is knowable within seconds even
    though provisioning hasn't begun). ansible/validate logs are never VMs."""
    provision, create = [], []
    try:
        entries = sorted(os.listdir(logdir))
    except OSError:
        return []
    for f in entries:
        if f.endswith(_CREATE_SUFFIX):
            stem = f[: -len(_CREATE_SUFFIX)]
            if stem not in _NON_VM_STEMS:
                create.append(stem)
        elif f.endswith(".log") and not f.endswith(_EXCLUDE_SUFFIX):
            stem = f[:-4]
            if stem not in _NON_VM_STEMS:
                provision.append(stem)
    return list(dict.fromkeys(provision + create))

CREATE_SETTLE_S = 180  # newest create-log must be this old before an exact
                       # match beats a still-possible superset profile

def _newest_create_age_s(logdir, now_epoch):
    """Seconds since the newest `<vm>-create.log` was written; None if no
    create-logs (non-up.sh logdir) or no clock provided."""
    if now_epoch is None:
        return None
    newest = None
    try:
        for f in os.listdir(logdir):
            if f.endswith(_CREATE_SUFFIX):
                m = os.stat(os.path.join(logdir, f)).st_mtime
                if newest is None or m > newest:
                    newest = m
    except OSError:
        return None
    if newest is None:
        return None
    return max(0.0, now_epoch - newest)

def infer_profile(logdir, profiles_dir, vbox_names=None, now_epoch=None):
    """Best-effort profile name from the logdir's VM stems. An exact
    component-set match wins ONLY when no other profile is a strict superset
    of the observed stems — during Phase 1 a partially-created larger lab can
    exactly impersonate a smaller one (lived it 2026-07-06: 7 of pqc-full's
    13 create-logs exactly matched ad-cs-two-tier — #210). While a superset
    remains possible the result is ambiguous, unless the newest create-log is
    older than CREATE_SETTLE_S: up.sh creates sequentially every ~30-60s, so
    a settled create phase means the superset's missing VMs are not coming
    and the exact match is trustworthy. Remaining ties (core vs
    ad-cs-one-tier share a component set; two labs both contain the observed
    stems) are broken by which single profile has registered VBox machines
    for every stem; still ambiguous → None — guessing wrong would plant
    phantom VMs (or hide real ones), which is worse than staying unknown."""
    stems = set(logdir_vm_stems(logdir))
    if not stems or not profiles_dir or not os.path.isdir(profiles_dir):
        return None
    exact, supersets = [], []
    for f in sorted(os.listdir(profiles_dir)):
        if not f.endswith(".yml"):
            continue
        comps = set(_from_profile_yaml(os.path.join(profiles_dir, f)))
        if not comps:
            continue
        if comps == stems:
            exact.append(f[:-4])
        elif stems < comps:
            supersets.append(f[:-4])
    if len(exact) == 1 and supersets:
        age = _newest_create_age_s(logdir, now_epoch)
        if age is not None and age >= CREATE_SETTLE_S:
            return exact[0]
        # Superset still possible and creates not settled: ambiguous.
        candidates = exact + supersets
    else:
        candidates = exact or supersets
    if len(candidates) == 1:
        return candidates[0]
    if vbox_names:
        # Coverage tie-break — but registration evidence is only about THIS
        # logdir once no larger lab can still be mid-creation (#217): during
        # an unsettled Phase 1, a STANDING lab that supersets the early stems
        # covers them all while the building lab hasn't registered its own
        # VMs yet, and the tie-break confidently returns the wrong (standing)
        # profile. Gate it on create-settle whenever any superset candidate
        # exists; with no superset candidates, stems cannot be a partial
        # build of anything known and the tie-break is safe immediately.
        # (No create-logs at all ⇒ not an up.sh Phase-1 context ⇒ settled.)
        tiebreak_ok = not supersets
        if not tiebreak_ok and now_epoch is not None:
            age = _newest_create_age_s(logdir, now_epoch)
            tiebreak_ok = age is None or age >= CREATE_SETTLE_S
        if tiebreak_ok:
            registered = set(vbox_names)
            covered = [c for c in candidates
                       if {f"straylight-{c}-{s}" for s in stems} <= registered]
            if len(covered) == 1:
                return covered[0]
    return None

def profile_components(profile, profiles_dir):
    """Component set for a profile name, or empty set when unknown."""
    if not profile or not profiles_dir:
        return set()
    p = os.path.join(profiles_dir, f"{profile}.yml")
    if not os.path.isfile(p):
        return set()
    return set(_from_profile_yaml(p))

def resolve(profile, logdir, vbox_names=None, profiles_dir=None):
    profiles_dir = profiles_dir or os.path.join(os.path.dirname(logdir.rstrip("/")), "profiles")
    if profile:
        p = os.path.join(profiles_dir, f"{profile}.yml")
        if os.path.isfile(p):
            vms = _from_profile_yaml(p)
            if vms:
                return _order(vms)
    vms = logdir_vm_stems(logdir)
    if vms:
        return _order(vms)
    if vbox_names:
        candidates = []
        if profile:
            candidates.append(profile)
        if os.path.isdir(profiles_dir):
            stems = [f[:-4] for f in os.listdir(profiles_dir) if f.endswith(".yml")]
            candidates.extend(sorted(stems, key=len, reverse=True))
        stripped = []
        for n in vbox_names:
            vm = None
            for cand in candidates:
                prefix = f"straylight-{cand}-"
                if n.startswith(prefix):
                    vm = n[len(prefix):]
                    break
            if vm is None:
                m = re.match(r"straylight-[^-]+-(.+)", n)
                vm = m.group(1) if m else n
            stripped.append(vm)
        return _order(stripped)
    return []

def vbox_name_map(profile, vms):
    return {v: f"straylight-{profile}-{v}" for v in vms}
