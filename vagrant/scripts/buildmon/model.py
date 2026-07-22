"""Thread-safe aggregate status model + snapshot serialization."""
from __future__ import annotations
import threading
from dataclasses import dataclass
from timefmt import iso_utc, dur_s

_RUNNING_STATES = {"creating", "booting", "provisioning", "rebooting", "waiting-dep"}

@dataclass
class VmRecord:
    name: str
    role: str | None = None
    order_index: int = 0
    state: str = "pending"
    vbox: str = "unknown"
    pid: int | None = None
    pid_alive: bool | None = None
    start_epoch: float | None = None
    task_name: str | None = None
    task_start_epoch: float | None = None
    last_result: str | None = None
    ok: int = 0
    changed: int = 0
    failed: int = 0
    reboots: int = 0
    stall_s: int = 0
    waiting_on: str | None = None
    guest: dict | None = None
    attempt: int = 1
    prior_failed: int = 0
    prior_interrupted: int = 0

class StatusModel:
    def __init__(self, profile, logdir, started_epoch, clock):
        self._lock = threading.RLock()
        self.profile = profile
        self.logdir = logdir
        self.started_epoch = started_epoch
        self.clock = clock
        self.phase = "creating"
        self._vms: dict[str, VmRecord] = {}

    def add_vm(self, name, role=None, order_index=0):
        with self._lock:
            if name not in self._vms:
                self._vms[name] = VmRecord(name=name, role=role, order_index=order_index)

    def get_vm(self, name):
        """Read-only snapshot of one VmRecord (or None). Thread-safe."""
        with self._lock:
            return self._vms.get(name)

    def update_vm(self, name, **fields):
        with self._lock:
            rec = self._vms.get(name)
            if rec is None:
                rec = VmRecord(name=name)
                self._vms[name] = rec
            changes = []
            for k, v in fields.items():
                old = getattr(rec, k)
                if old != v:
                    setattr(rec, k, v)
                    changes.append((k, old, v))
            return changes

    def set_phase(self, phase):
        with self._lock:
            if phase == self.phase:
                return None
            old = self.phase
            self.phase = phase
            return (old, phase)

    def snapshot(self, now_epoch):
        with self._lock:
            counts = {"total": len(self._vms), "pending": 0, "running": 0,
                      "done": 0, "failed": 0, "hung": 0}
            vms = {}
            for name, r in sorted(self._vms.items(), key=lambda kv: kv[1].order_index):
                if r.state == "pending":
                    counts["pending"] += 1
                elif r.state == "done":
                    counts["done"] += 1
                elif r.state == "failed":
                    counts["failed"] += 1
                elif r.state == "hung":
                    counts["hung"] += 1
                elif r.state in _RUNNING_STATES:
                    counts["running"] += 1
                task = None
                if r.task_name is not None:
                    task = {"name": r.task_name,
                            "started_at": iso_utc(r.task_start_epoch) if r.task_start_epoch else None,
                            "duration_s": dur_s(r.task_start_epoch, now_epoch) if r.task_start_epoch else 0}
                result = None
                if r.last_result is not None or r.ok or r.changed or r.failed:
                    result = {"last": r.last_result, "ok": r.ok, "changed": r.changed, "failed": r.failed}
                vms[name] = {
                    "state": r.state, "role": r.role, "vbox": r.vbox,
                    "pid": r.pid, "pid_alive": r.pid_alive,
                    "elapsed_s": dur_s(r.start_epoch, now_epoch) if r.start_epoch else 0,
                    "task": task, "result": result,
                    "reboots": r.reboots, "stall_s": r.stall_s, "waiting_on": r.waiting_on,
                    "guest": r.guest,
                }
                if r.attempt > 1:
                    vms[name]["attempt"] = r.attempt
                    vms[name]["prior"] = {"failed": r.prior_failed,
                                          "interrupted": r.prior_interrupted}
            return {
                "schema": "buildmon/v1",
                "build": {
                    "profile": self.profile, "logdir": self.logdir, "phase": self.phase,
                    "started_at": iso_utc(self.started_epoch), "updated_at": iso_utc(now_epoch),
                    "elapsed_s": dur_s(self.started_epoch, now_epoch), "counts": counts,
                },
                "vms": vms,
            }
