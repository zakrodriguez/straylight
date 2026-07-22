"""Wire sources → model → feed. Host-side main loop with collector isolation."""
from __future__ import annotations
import os
import signal
from logtail import LogTailer
from timefmt import iso_utc, dur_s
from topology import ROLE_HINTS, logdir_vm_stems, infer_profile, profile_components
import history
import phase as phase_mod

# When the profile is unknown, retry inference every this-many ticks even
# without a new adoption — the create-settle heuristic (topology.infer_profile)
# needs the retry to eventually resolve an exact-vs-superset ambiguity (#210).
REINFER_EVERY_TICKS = 12

def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False

class Collector:
    def __init__(self, logdir, profile, model, feed, tailers, vboxpoller, guestpool,
                 clock, pid_map=None, hang_threshold_s=600, profiles_dir=None, logger=None,
                 alerts=None, prober_factory=None):
        self.logdir = logdir
        self.profile = profile
        self.model = model
        self.feed = feed
        self.tailers = tailers
        self.vbox = vboxpoller
        self.pool = guestpool
        self.clock = clock
        self.pid_map = pid_map or {}
        self.hang_threshold_s = hang_threshold_s
        self.profiles_dir = profiles_dir
        self.logger = logger
        self.alerts = alerts
        # (vm, profile) -> GuestProber|None; lets probers be wired for VMs
        # that appear after startup (adoption) or once the profile is known
        # (late inference) instead of staying dark for the whole run.
        self.prober_factory = prober_factory
        self._prev_snapshot = None
        self._prev_vbox = {}
        self._attempts = {}
        self._reboot_track = {}  # vm -> {"window": bool, "counted": bool,
                                 #        "prev_reachable": bool|None, "last_boot": str|None}
        self._alerted_prev_states = {}
        self._alerted_prev_phase = None
        self._ticks = 0
        self._ignored_stems = set()
        self._stop = False

    def _safe(self, source, fn, default):
        try:
            return fn()
        except Exception as exc:
            if self.logger:
                self.logger(f"collector source {source} failed: {exc!r}")
            return default

    def load_attempts_and_stamp(self):
        """Scan sibling logdirs once the profile is known and stamp every
        currently-tracked VM. Safe to call again if the profile is learned
        late (re-scan, re-stamp)."""
        if not self.profile:
            return
        self._attempts = self._safe(
            "attempts",
            lambda: history.scan_attempts(self.logdir, self.profile,
                                          profiles_dir=self.profiles_dir),
            {}) or {}
        for vm in list(self.tailers):
            self._stamp_attempts(vm)

    def _wire_prober(self, vm):
        """Best-effort: give vm a guest prober if the pool lacks one and the
        profile is known. Soft-fail — probing is telemetry, never load-bearing."""
        if not self.prober_factory or not self.profile:
            return
        try:
            if self.pool.has(vm):
                return
            prober = self.prober_factory(vm, self.profile)
            if prober is not None:
                self.pool.add_prober(vm, prober)
                if self.logger:
                    self.logger(f"guest probe wired for adopted VM '{vm}'")
        except Exception as exc:
            if self.logger:
                self.logger(f"guest probe wiring failed for {vm}: {exc!r}")

    def _stamp_attempts(self, vm):
        a = self._attempts.get(vm)
        if not a or a.get("attempt", 1) <= 1:
            return
        self.model.update_vm(vm, attempt=a["attempt"],
                             prior_failed=a["prior"]["failed"],
                             prior_interrupted=a["prior"]["interrupted"])

    def _note_reboot_signals(self, vm, new_state, guest, vbox_edge):
        """Fuse VBox edge / TCP flap / last_boot advance into at most one
        reboots increment per reboot window; last_boot advance outside a
        window counts once per distinct value (unexpected reboot)."""
        t = self._reboot_track.setdefault(
            vm, {"window": False, "counted": False, "prev_reachable": None, "last_boot": None})
        was_in_window = t["window"]
        in_window = new_state == "rebooting"
        if in_window and not was_in_window:
            t["counted"] = False   # window opens
        # The tick a window closes is exactly the tick the VBox reboot edge
        # (or a late flap/last_boot advance) typically fires — treat it as
        # still "in window" for signal-catching purposes (one-tick grace)
        # so the closing-tick edge isn't silently dropped.
        active_window = in_window or was_in_window
        inc = 0
        reachable = guest.get("reachable") if guest else None
        flap = t["prev_reachable"] is False and reachable is True
        lb = guest.get("last_boot") if guest else None
        lb_advance = bool(lb) and t["last_boot"] is not None and lb != t["last_boot"]
        if active_window:
            if not t["counted"] and (vbox_edge or flap or lb_advance):
                inc, t["counted"] = 1, True
        elif lb_advance:
            inc = 1
        t["window"] = in_window
        if reachable is not None:
            t["prev_reachable"] = reachable
        if lb:
            t["last_boot"] = lb
        return inc

    def _dispatch_alerts(self, vm_states, build_phase):
        """vm failed/hung transitions + build done/failed phase transitions."""
        if not self.alerts:
            return
        base = {"profile": self.profile, "logdir": self.logdir}
        for vm, st in vm_states.items():
            if st in ("failed", "hung") and self._alerted_prev_states.get(vm) != st:
                rec = self.model.get_vm(vm)
                self.alerts.dispatch(
                    "vm_failed" if st == "failed" else "vm_hung", vm,
                    {**base, "state": st,
                     "attempt": getattr(rec, "attempt", 1) if rec else 1})
        self._alerted_prev_states = dict(vm_states)
        if build_phase in ("done", "failed") and build_phase != self._alerted_prev_phase:
            self.alerts.dispatch("build_done" if build_phase == "done" else "build_failed",
                                 None, {**base, "state": build_phase})
        self._alerted_prev_phase = build_phase

    def _adopt_new_logs(self):
        """Self-heal the tracked VM set: a `<vm>.log` or `<vm>-create.log` appearing
        in the logdir that we aren't tracking (wrong/absent --profile, VM added
        mid-build, collector started before Phase 1 wrote anything) gets adopted, so
        the feed follows the build actually happening rather than the one assumed.
        Create-log-only VMs tail the (future) `<vm>.log` path and sit at `pending`
        until provisioning starts. When the profile is known, adopted VMs also get
        their VBox machine name mapped — essential when several straylight labs are
        registered simultaneously and bare stems like `dc1` are ambiguous."""
        adopted = False
        comps = profile_components(self.profile, self.profiles_dir) if self.profile else set()
        for stem in logdir_vm_stems(self.logdir):
            if stem in self.tailers or stem in self._ignored_stems:
                continue
            # With a known profile, a bare `<vm>.log` that is neither a
            # component nor backed by a `<vm>-create.log` is a helper log
            # (e.g. web1-reload.log from a manual recovery), not a VM —
            # adopting it plants a phantom row that never finishes (#214).
            # Create-log-backed stems are always real (up.sh wrote them);
            # component stems without create-logs cover snapshot restores.
            if comps and stem not in comps and not os.path.isfile(
                    os.path.join(self.logdir, f"{stem}-create.log")):
                self._ignored_stems.add(stem)
                if self.logger:
                    self.logger(f"ignoring log stem '{stem}': not a component of "
                                f"profile '{self.profile}' and no create-log")
                continue
            adopted = True
            self.tailers[stem] = LogTailer(os.path.join(self.logdir, f"{stem}.log"), self.clock)
            self.model.add_vm(stem, role=ROLE_HINTS.get(stem), order_index=len(self.tailers))
            self._stamp_attempts(stem)
            if self.profile:
                self.vbox.name_map.setdefault(stem, f"straylight-{self.profile}-{stem}")
            self._wire_prober(stem)
            if self.logger:
                self.logger(f"adopted VM '{stem}' from logdir (not in resolved topology)")
        if adopted and not self.profile:
            self._late_infer_profile()

    def _late_infer_profile(self, now_epoch=None):
        """A collector attached in the first seconds of a build sees too few
        create-logs to identify the profile. Every adoption is another chance —
        and so is every REINFER_EVERY_TICKS-th tick, because an exact-vs-superset
        ambiguity (#210) only resolves once the create phase settles, which
        produces no new adoption to piggyback on. Once the VM set pins a single
        profile, adopt it — the VBox machine names (straylight-<profile>-<vm>)
        only resolve with it, which is what keeps concurrent labs with
        same-named VMs (dc1, rootca, ...) apart."""
        try:
            from vbox import list_registered
            names = list(list_registered(self.vbox.runner).keys())
        except Exception:
            names = None
        p = infer_profile(self.logdir, self.profiles_dir, vbox_names=names,
                          now_epoch=now_epoch if now_epoch is not None else self.clock.now())
        if not p:
            return
        self.profile = p
        self.model.profile = p
        for vm in self.tailers:
            self.vbox.name_map.setdefault(vm, f"straylight-{p}-{vm}")
            self._wire_prober(vm)
        self.load_attempts_and_stamp()
        if self.logger:
            self.logger(f"inferred profile '{p}' from logdir contents")

    def _read_pidfile(self, vm):
        """Best-effort PID for vm from <logdir>/<vm>.pid, written by up.sh
        when it backgrounds that VM's provision job. Re-read every tick
        (never cached) so a PID that appears after buildmon attaches — the
        common case — or changes across a rebuild is always picked up.
        Falls back to the constructor-supplied pid_map (mainly for tests
        and any caller that already has PIDs some other way)."""
        try:
            with open(os.path.join(self.logdir, f"{vm}.pid")) as fh:
                return int(fh.read().strip())
        except (OSError, ValueError):
            return None

    def tick(self, now_epoch):
        self._safe("adopt", self._adopt_new_logs, None)
        if not self.profile and self._ticks % REINFER_EVERY_TICKS == 0:
            self._safe("reinfer", lambda: self._late_infer_profile(now_epoch), None)
        self._ticks += 1
        vm_states = {}
        for vm, tailer in self.tailers.items():
            log = self._safe(f"log:{vm}", tailer.read, None)
            vbox = self._safe(f"vbox:{vm}", lambda: self.vbox.poll(vm)["vbox"], "unknown")
            reboot = self._safe(f"reboot:{vm}",
                                lambda: self.vbox.detect_reboot(vm, self._prev_vbox.get(vm, "unknown"), vbox),
                                False)
            self._prev_vbox[vm] = vbox
            pid = self._safe(f"pidfile:{vm}", lambda: self._read_pidfile(vm), None) or self.pid_map.get(vm)
            alive = pid_alive(pid) if pid else None
            stall_s = 0
            if log and log.mtime_epoch:
                stall_s = dur_s(log.mtime_epoch, now_epoch)
            from_rec = self.model.get_vm(vm)
            prev_state = from_rec.state if from_rec else "pending"
            log_reboot_active = bool(log and log.task_name and phase_mod._REBOOT_TASK_RE.search(log.task_name))
            new_state = phase_mod.derive_vm_state(prev_state, log or _empty_log(), vbox, alive,
                                                  reboot, stall_s, self.hang_threshold_s)
            waiting_on = phase_mod.detect_waiting_on(log.task_name if log else None)
            fields = {"state": new_state, "vbox": vbox, "pid": pid, "pid_alive": alive,
                      "stall_s": stall_s, "waiting_on": waiting_on}
            if log and log.exists:
                if log.task_name:
                    cur = self.model.get_vm(vm)
                    if not cur or cur.task_name != log.task_name:
                        fields["task_name"] = log.task_name
                        fields["task_start_epoch"] = now_epoch
                fields["last_result"] = log.last_result
                fields["ok"] = log.ok
                fields["changed"] = log.changed
                fields["failed"] = log.failed
            g = self._safe(f"guest:{vm}", lambda: self.pool.latest(vm), None)
            if g is not None:
                fields["guest"] = g
            inc = self._safe(f"rebootsig:{vm}",
                             lambda: self._note_reboot_signals(vm, new_state, g, reboot), 0)
            if inc:
                cur = self.model.get_vm(vm)
                fields["reboots"] = (cur.reboots if cur else 0) + inc
            if from_rec and from_rec.start_epoch is None and new_state != "pending":
                fields["start_epoch"] = now_epoch
            self.model.update_vm(vm, **fields)
            self.pool.set_context(vm, vbox, log_reboot_active)
            vm_states[vm] = new_state
        self.model.set_phase(phase_mod.derive_build_phase(vm_states, "dc1" in self.tailers))
        self._safe("alerts", lambda: self._dispatch_alerts(vm_states, self.model.phase), None)
        snap = self.model.snapshot(now_epoch)
        self._safe("feed", lambda: self.feed.write_status(snap), None)
        self._safe("events", lambda: self.feed.emit_transitions(self._prev_snapshot, snap, iso_utc(now_epoch)), None)
        self._prev_snapshot = snap

    def run(self, interval_s=5, max_ticks=None):
        def _handler(signum, frame):
            self._stop = True
        signal.signal(signal.SIGINT, _handler)
        signal.signal(signal.SIGTERM, _handler)
        ticks = 0
        while not self._stop:
            self.tick(self.clock.now())
            ticks += 1
            if max_ticks is not None and ticks >= max_ticks:
                break
            self.clock.sleep(interval_s)
        # final flush + monitor stop event
        self.tick(self.clock.now())
        self._safe("stopmark",
                   lambda: self.feed.append_event({"ts": iso_utc(self.clock.now()),
                                                   "kind": "monitor", "event": "stopped"}),
                   None)
        self.pool.stop()

def _empty_log():
    from logtail import LogState
    return LogState(exists=False)
