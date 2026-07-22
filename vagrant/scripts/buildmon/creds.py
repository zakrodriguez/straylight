"""Per-VM probe transport descriptors, resolved from the repo's own sources.

Primary source is the profile's rendered inventory
(ansible/inventory/<profile>/static.ini) — the exact connection facts
ansible itself uses for the whole build. Pure key=value parsing; nothing is
ever eval'd. Resolution failures return {"available": False, ...} and never
raise — an unresolvable VM simply stays dark to the probe pool.
"""
from __future__ import annotations
import os


def load_inventory(path):
    """{vm: {key: value}} from a static.ini; {} on any read problem."""
    out = {}
    try:
        with open(path) as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or line.startswith("["):
                    continue
                parts = line.split()
                kv = {}
                for tok in parts[1:]:
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        kv[k] = v
                out[parts[0]] = kv
    except OSError:
        return {}
    return out


def _unavailable(vm, reason):
    return {"available": False, "vm": vm, "reason": reason}


def resolve(vm, profile, vagrant_root):
    """Transport descriptor for one VM, or available=False with a reason."""
    if not profile:
        return _unavailable(vm, "no profile")
    inv_path = os.path.join(vagrant_root, "ansible", "inventory", profile, "static.ini")
    inv = load_inventory(inv_path)
    if not inv:
        return _unavailable(vm, f"inventory not readable: {inv_path}")
    kv = inv.get(vm)
    if kv is None:
        return _unavailable(vm, "vm not in inventory")
    ip = kv.get("ansible_host")
    if not ip:
        return _unavailable(vm, "no ansible_host in inventory")
    conn = kv.get("ansible_connection", "ssh")
    user = kv.get("ansible_user", "vagrant")
    if conn == "winrm":
        try:
            port = int(kv.get("ansible_port", 5985))
        except (TypeError, ValueError):
            return _unavailable(vm, "invalid ansible_port in inventory")
        return {"available": True, "transport": "winrm", "vm": vm, "ip": ip,
                "port": port, "user": user,
                "password": kv.get("ansible_password", "vagrant"),
                "ip_source": "inventory"}
    key = os.path.join(vagrant_root, f".vagrant-{profile}", "machines", vm,
                       "virtualbox", "private_key")
    if not os.path.isfile(key):
        return _unavailable(vm, f"no ssh private key at {key}")
    return {"available": True, "transport": "ssh", "vm": vm, "ip": ip,
            "port": 22, "user": user, "key": key, "ip_source": "inventory"}
