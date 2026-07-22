"""Per-VM guest-probe threads with concurrency cap + backoff. Isolated from host loop."""
from __future__ import annotations
import random
import threading

class GuestProbePool:
    def __init__(self, probers, clock, max_concurrent=2, period_s=45, jitter_s=10, enabled=True):
        self.probers = probers
        self.clock = clock
        self.enabled = enabled
        self.period_s = period_s
        self.jitter_s = jitter_s
        self._sem = threading.Semaphore(max_concurrent)
        self._latest = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._threads = []
        self._started = False
        # backoff inputs updated by the collector each host tick:
        self._vbox = {vm: "unknown" for vm in probers}
        self._reboot_active = {vm: False for vm in probers}

    def has(self, vm):
        return vm in self.probers

    def add_prober(self, vm, prober):
        """Register a prober after construction (VM adopted mid-run, or the
        profile learned late so descriptors only just became resolvable).
        Enables a pool that started empty and spawns the probe thread when
        the pool is already running. Idempotent per VM."""
        if vm in self.probers:
            return
        self.probers[vm] = prober
        self._vbox.setdefault(vm, "unknown")
        self._reboot_active.setdefault(vm, False)
        self.enabled = True
        if self._started:
            th = threading.Thread(target=self._run_vm, args=(vm, prober), daemon=True)
            th.start()
            self._threads.append(th)

    def set_context(self, vm, vbox_state, log_reboot_active):
        self._vbox[vm] = vbox_state
        self._reboot_active[vm] = log_reboot_active

    def should_probe(self, vm, vbox_state, log_reboot_active):
        if not self.enabled:
            return False
        if vbox_state in ("poweroff", "saved", "aborted", "paused"):
            return False
        if log_reboot_active:
            return False
        return True

    def latest(self, vm):
        with self._lock:
            return self._latest.get(vm)

    def _run_vm(self, vm, prober):
        while not self._stop.is_set():
            try:
                if self.should_probe(vm, self._vbox.get(vm, "unknown"), self._reboot_active.get(vm, False)):
                    acquired = self._sem.acquire(timeout=1.0)
                    if not acquired:
                        continue          # re-check _stop instead of parking forever
                    try:
                        if self._stop.is_set():
                            continue      # stop won the race; finally releases the slot
                        result = prober.probe()
                        with self._lock:
                            self._latest[vm] = result
                    finally:
                        self._sem.release()
                self.clock.sleep(max(0.0, self.period_s + random.uniform(0, max(0.0, self.jitter_s))))
            except Exception:
                pass  # collector-isolation: never let a probe thread die loudly

    def start(self):
        # Mark started even when currently disabled (no probers yet): a later
        # add_prober must be able to spin its thread up instead of the pool
        # staying dark for the whole run.
        self._started = True
        if not self.enabled:
            return
        for vm, prober in self.probers.items():
            th = threading.Thread(target=self._run_vm, args=(vm, prober), daemon=True)
            th.start()
            self._threads.append(th)

    def stop(self):
        self._stop.set()
        for th in self._threads:
            th.join(timeout=2)
