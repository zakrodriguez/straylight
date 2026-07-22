import json, os, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from clock import FakeClock  # noqa: E402
from model import StatusModel  # noqa: E402
from feed import FeedWriter  # noqa: E402
from logtail import LogTailer  # noqa: E402
from collector import Collector  # noqa: E402

class _StubVbox:
    def __init__(self, state="running"): self.state = state; self.name_map = {}
    def poll(self, vm): return {"vbox": self.state, "uptime_s": None}
    def detect_reboot(self, vm, prev, new): return False

class _StubPool:
    def __init__(self): self.added = {}
    def latest(self, vm): return None
    def set_context(self, *a, **k): pass
    def should_probe(self, *a, **k): return False
    def has(self, vm): return vm in self.added
    def add_prober(self, vm, prober): self.added[vm] = prober

class TestCollectorTick(unittest.TestCase):
    def test_single_tick_writes_feed(self):
        with tempfile.TemporaryDirectory() as d:
            logdir = d
            with open(os.path.join(logdir, "dc1.log"), "w") as fh:
                fh.write("TASK [domain_controller : Create Autoenrollment GPO] ***\nchanged: [dc1]\n")
            outdir = os.path.join(logdir, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("core", logdir, 1000.0, clk)
            model.add_vm("dc1", role="domain_controller", order_index=0)
            feed = FeedWriter(outdir)
            col = Collector(logdir, "core", model, feed,
                            tailers={"dc1": LogTailer(os.path.join(logdir, "dc1.log"), clk)},
                            vboxpoller=_StubVbox(), guestpool=_StubPool(), clock=clk,
                            pid_map={"dc1": os.getpid()})   # our own pid = alive
            clk.advance(60)
            col.tick(clk.now())
            snap = json.load(open(os.path.join(outdir, "status.json")))
            self.assertEqual(snap["vms"]["dc1"]["task"]["name"],
                             "domain_controller : Create Autoenrollment GPO")
            self.assertIn(snap["vms"]["dc1"]["state"], ("provisioning", "waiting-dep"))
            self.assertTrue(os.path.exists(os.path.join(outdir, "events.ndjson")))

class _ScriptedVbox:
    """Returns vbox states from a per-vm list, advancing one step per poll-round."""
    def __init__(self, script): self.script = script; self.i = {vm: 0 for vm in script}
    def poll(self, vm):
        seq = self.script[vm]; idx = min(self.i[vm], len(seq) - 1)
        return {"vbox": seq[idx], "uptime_s": None}
    def advance(self):
        for vm in self.i: self.i[vm] += 1
    def detect_reboot(self, vm, prev, new):
        return prev in ("poweroff", "saved", "aborted") and new == "running"

class TestReplay(unittest.TestCase):
    def test_phase_progression_and_events(self):
        import json
        with tempfile.TemporaryDirectory() as d:
            logdir = d; outdir = os.path.join(d, "buildmon")
            dc1 = os.path.join(logdir, "dc1.log"); ca1 = os.path.join(logdir, "ca1.log")
            clk = FakeClock(0.0)
            model = StatusModel("core", logdir, 0.0, clk)
            model.add_vm("dc1", "domain_controller", 0); model.add_vm("ca1", "subordinate_ca", 1)
            feed = FeedWriter(outdir)
            vbox = _ScriptedVbox({"dc1": ["running", "running", "poweroff", "running", "running"],
                                  "ca1": ["running", "running", "running", "running", "running"]})
            col = Collector(logdir, "core", model, feed,
                            tailers={"dc1": LogTailer(dc1, clk), "ca1": LogTailer(ca1, clk)},
                            vboxpoller=vbox, guestpool=_StubPool(), clock=clk,
                            pid_map={"dc1": os.getpid(), "ca1": os.getpid()})
            phases = []
            # tick 0: nothing yet
            col.tick(clk.now()); phases.append(model.phase); clk.advance(30); vbox.advance()
            # tick 1: dc1 provisioning
            open(dc1, "w").write("TASK [domain_controller : Promote to DC] ***\nchanged: [dc1]\n")
            col.tick(clk.now()); phases.append(model.phase); clk.advance(30); vbox.advance()
            # tick 2: dc1 reboot (vbox poweroff)
            col.tick(clk.now()); phases.append(model.phase); clk.advance(30); vbox.advance()
            # tick 3: dc1 back + ca1 provisioning → parallel
            open(dc1, "a").write("TASK [domain_controller : Create Autoenrollment GPO] ***\nchanged: [dc1]\n")
            open(ca1, "w").write("TASK [subordinate_ca : Install CA] ***\nchanged: [ca1]\n")
            col.tick(clk.now()); phases.append(model.phase); clk.advance(30); vbox.advance()
            # tick 4: both done
            for f in (dc1, ca1):
                open(f, "a").write("\nPLAY RECAP ***\n%s : ok=50 changed=20 unreachable=0 failed=0\n"
                                   % os.path.basename(f)[:-4])
            # mark pids dead by using a pid that isn't alive
            col.pid_map = {"dc1": 999999999, "ca1": 999999999}
            col.tick(clk.now()); phases.append(model.phase)

            self.assertIn("dc1-provision", phases)
            self.assertIn("parallel-provision", phases)
            self.assertEqual(phases[-1], "done")
            events = [json.loads(l) for l in open(os.path.join(outdir, "events.ndjson"))]
            kinds = [(e.get("vm"), e["kind"]) for e in events]
            self.assertIn(("dc1", "reboot"), kinds)
            self.assertTrue(any(e["kind"] == "task" and e.get("vm") == "dc1" for e in events))
            self.assertTrue(any(e["kind"] == "done" for e in events))


class TestAdoptFromLogdir(unittest.TestCase):
    def _mkprofile(self, root, name, comps):
        pdir = os.path.join(root, "profiles"); os.makedirs(pdir, exist_ok=True)
        with open(os.path.join(pdir, f"{name}.yml"), "w") as fh:
            fh.write("components:\n" + "".join(f"  - {c}\n" for c in comps))
        return pdir

    def test_helper_log_not_adopted_as_phantom_vm(self):
        # A `web1-reload.log` dropped in the logdir by a manual recovery is
        # neither a profile component nor create-log-backed — adopting it
        # planted a phantom VM that sat "provisioning" forever (#214).
        with tempfile.TemporaryDirectory() as root:
            pdir = self._mkprofile(root, "pqc", ["dc1", "web1"])
            d = os.path.join(root, "logs"); os.makedirs(d)
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("pqc", d, 1000.0, clk)
            notes = []
            col = Collector(d, "pqc", model, FeedWriter(outdir),
                            tailers={}, vboxpoller=_StubVbox(), guestpool=_StubPool(),
                            clock=clk, pid_map={}, profiles_dir=pdir, logger=notes.append)
            open(os.path.join(d, "web1-create.log"), "w").close()
            with open(os.path.join(d, "web1.log"), "w") as fh:
                fh.write("TASK [common : x] ***\nok: [web1]\n")
            with open(os.path.join(d, "web1-reload.log"), "w") as fh:
                fh.write("==> web1: Attempting graceful shutdown of VM...\n")
            col.tick(clk.now())
            snap = json.load(open(os.path.join(outdir, "status.json")))
            self.assertIn("web1", snap["vms"])
            self.assertNotIn("web1-reload", snap["vms"])
            self.assertTrue(any("ignoring log stem 'web1-reload'" in n for n in notes))

    def test_component_without_create_log_still_adopted(self):
        # Snapshot-restored VMs never get a `<vm>-create.log`; being a profile
        # component is enough.
        with tempfile.TemporaryDirectory() as root:
            pdir = self._mkprofile(root, "core", ["dc1", "ca1"])
            d = os.path.join(root, "logs"); os.makedirs(d)
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("core", d, 1000.0, clk)
            col = Collector(d, "core", model, FeedWriter(outdir),
                            tailers={}, vboxpoller=_StubVbox(), guestpool=_StubPool(),
                            clock=clk, pid_map={}, profiles_dir=pdir)
            with open(os.path.join(d, "ca1.log"), "w") as fh:
                fh.write("TASK [subordinate_ca : Install CA] ***\nchanged: [ca1]\n")
            col.tick(clk.now())
            snap = json.load(open(os.path.join(outdir, "status.json")))
            self.assertIn("ca1", snap["vms"])

    def test_create_log_backed_stem_adopted_even_if_not_component(self):
        # A create-log means up.sh really created the VM — always real, even
        # under a wrong/mislabelled profile (the #210 misbind scenario must
        # not blind the feed to the extra VMs).
        with tempfile.TemporaryDirectory() as root:
            pdir = self._mkprofile(root, "two-tier", ["dc1"])
            d = os.path.join(root, "logs"); os.makedirs(d)
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("two-tier", d, 1000.0, clk)
            col = Collector(d, "two-tier", model, FeedWriter(outdir),
                            tailers={}, vboxpoller=_StubVbox(), guestpool=_StubPool(),
                            clock=clk, pid_map={}, profiles_dir=pdir)
            open(os.path.join(d, "rootca-pqc-create.log"), "w").close()
            col.tick(clk.now())
            snap = json.load(open(os.path.join(outdir, "status.json")))
            self.assertIn("rootca-pqc", snap["vms"])

    def test_untracked_vm_log_is_adopted(self):
        with tempfile.TemporaryDirectory() as d:
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("wrong-profile", d, 1000.0, clk)
            # Collector starts tracking NOTHING (e.g. wrong --profile resolved 0 overlap)
            notes = []
            col = Collector(d, "wrong-profile", model, FeedWriter(outdir),
                            tailers={}, vboxpoller=_StubVbox(), guestpool=_StubPool(),
                            clock=clk, pid_map={}, logger=notes.append)
            # a real provision log appears for a VM outside the resolved topology
            with open(os.path.join(d, "ca1.log"), "w") as fh:
                fh.write("TASK [subordinate_ca : Install CA] ***\nchanged: [ca1]\n")
            # non-VM logs must NOT be adopted
            open(os.path.join(d, "ansible.log"), "w").close()
            open(os.path.join(d, "dc1-create.log"), "w").close()
            col.tick(clk.now())
            snap = json.load(open(os.path.join(outdir, "status.json")))
            self.assertIn("ca1", snap["vms"])
            self.assertEqual(snap["vms"]["ca1"]["role"], "subordinate_ca")
            self.assertEqual(snap["vms"]["ca1"]["task"]["name"], "subordinate_ca : Install CA")
            self.assertNotIn("ansible", snap["vms"])
            self.assertNotIn("dc1-create", snap["vms"])
            self.assertTrue(any("adopted VM 'ca1'" in n for n in notes))

    def test_create_log_adopted_as_pending_with_vbox_name(self):
        with tempfile.TemporaryDirectory() as d:
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("pqc-full", d, 1000.0, clk)
            vbox = _StubVbox()
            col = Collector(d, "pqc-full", model, FeedWriter(outdir),
                            tailers={}, vboxpoller=vbox, guestpool=_StubPool(),
                            clock=clk, pid_map={})
            # Phase 1: only the create log exists — provisioning hasn't started
            open(os.path.join(d, "stepca1-create.log"), "w").close()
            col.tick(clk.now())
            snap = json.load(open(os.path.join(outdir, "status.json")))
            self.assertIn("stepca1", snap["vms"])
            self.assertIn(snap["vms"]["stepca1"]["state"], ("pending", "booting"))
            # adopted VM gets its VBox machine name mapped — with several
            # straylight labs registered at once, bare "stepca1" is ambiguous
            self.assertEqual(vbox.name_map["stepca1"], "straylight-pqc-full-stepca1")

    def test_late_profile_inference_when_started_too_early(self):
        # Collector attached seconds into Phase 1: one create-log fits many
        # profiles (no profile), but once enough logs appear to pin a single
        # one, the collector adopts it and retrofits the VBox name map.
        with tempfile.TemporaryDirectory() as root:
            pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
            with open(os.path.join(pdir, "small.yml"), "w") as fh:
                fh.write("components:\n  - dc1\n  - web1\n")
            with open(os.path.join(pdir, "pqc.yml"), "w") as fh:
                fh.write("components:\n  - dc1\n  - web1\n  - rootca-pqc\n")
            d = os.path.join(root, "logs"); os.makedirs(d)
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("unknown", d, 1000.0, clk)
            vbox = _StubVbox()
            col = Collector(d, None, model, FeedWriter(outdir),
                            tailers={}, vboxpoller=vbox, guestpool=_StubPool(),
                            clock=clk, pid_map={}, profiles_dir=pdir)
            open(os.path.join(d, "dc1-create.log"), "w").close()
            col.tick(clk.now())                       # dc1 alone: ambiguous
            self.assertIsNone(col.profile)
            open(os.path.join(d, "web1-create.log"), "w").close()
            open(os.path.join(d, "rootca-pqc-create.log"), "w").close()
            clk.advance(5)
            col.tick(clk.now())                       # now only 'pqc' fits
            self.assertEqual(col.profile, "pqc")
            self.assertEqual(vbox.name_map["dc1"], "straylight-pqc-dc1")
            snap = json.load(open(os.path.join(outdir, "status.json")))
            self.assertEqual(snap["build"]["profile"], "pqc")


class TestCollectorAttemptStamp(unittest.TestCase):
    def test_prior_failure_stamped_onto_record(self):
        import tempfile, os, time
        from clock import Clock
        from model import StatusModel
        from feed import FeedWriter
        from logtail import LogTailer
        from vbox import VBoxPoller
        from guestpool import GuestProbePool
        from collector import Collector
        import history

        with tempfile.TemporaryDirectory() as root:
            pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
            open(os.path.join(pdir, "core.yml"), "w").write("components:\n  - dc1\n")
            # prior failed run
            old = os.path.join(root, "20260702-100000"); os.makedirs(old + "/buildmon")
            open(old + "/buildmon/status.json", "w").write(
                '{"build":{"profile":"core"},"vms":{"dc1":{"state":"failed"}}}')
            open(old + "/dc1.log", "w").write("TASK [x] ***\nchanged: [dc1]\n")
            # live run
            cur = os.path.join(root, "20260702-120000"); os.makedirs(cur)
            open(cur + "/dc1.log", "w").write("TASK [y] ***\n")
            clock = Clock()
            model = StatusModel("core", cur, time.time(), clock)
            model.add_vm("dc1", order_index=0)
            outdir = os.path.join(cur, "buildmon"); os.makedirs(outdir)
            col = Collector(cur, "core", model, feed=FeedWriter(outdir),
                            tailers={"dc1": LogTailer(cur + "/dc1.log", clock)},
                            vboxpoller=VBoxPoller({}, clock=clock),
                            guestpool=GuestProbePool({}, clock=clock, enabled=False),
                            clock=clock, profiles_dir=pdir, logger=lambda m: None)
            col.load_attempts_and_stamp()   # collector API added in this task
            rec = model.get_vm("dc1")
            self.assertEqual(rec.attempt, 2)
            self.assertEqual(rec.prior_failed, 1)


class TestLateProfileReStamp(unittest.TestCase):
    def test_late_profile_inference_restamps_existing_vm(self):
        import tempfile, os, time
        from clock import Clock
        from model import StatusModel
        from feed import FeedWriter
        from logtail import LogTailer
        from vbox import VBoxPoller
        from guestpool import GuestProbePool
        from collector import Collector

        with tempfile.TemporaryDirectory() as root:
            pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
            open(os.path.join(pdir, "core.yml"), "w").write("components:\n  - dc1\n")
            # prior failed run
            old = os.path.join(root, "20260702-100000"); os.makedirs(old + "/buildmon")
            open(old + "/buildmon/status.json", "w").write(
                '{"build":{"profile":"core"},"vms":{"dc1":{"state":"failed"}}}')
            open(old + "/dc1.log", "w").write("TASK [x] ***\nchanged: [dc1]\n")
            # live run — profile not yet known to the collector (e.g. attached
            # before --profile could be resolved)
            cur = os.path.join(root, "20260702-120000"); os.makedirs(cur)
            open(cur + "/dc1.log", "w").write("TASK [y] ***\n")
            clock = Clock()
            model = StatusModel("unknown", cur, time.time(), clock)
            model.add_vm("dc1", order_index=0)
            outdir = os.path.join(cur, "buildmon"); os.makedirs(outdir)
            col = Collector(cur, None, model, feed=FeedWriter(outdir),
                            tailers={"dc1": LogTailer(cur + "/dc1.log", clock)},
                            vboxpoller=VBoxPoller({}, clock=clock),
                            guestpool=GuestProbePool({}, clock=clock, enabled=False),
                            clock=clock, profiles_dir=pdir, logger=lambda m: None)

            # profile unknown at construction: call is a no-op
            col.load_attempts_and_stamp()
            rec = model.get_vm("dc1")
            self.assertEqual(rec.attempt, 1)
            self.assertEqual(col._attempts, {})

            # profile resolves later (mimics what _late_infer_profile does
            # once enough create-logs pin a single profile)
            col.profile = "core"
            col.model.profile = "core"
            col.load_attempts_and_stamp()

            rec = model.get_vm("dc1")
            self.assertEqual(rec.attempt, 2)
            self.assertEqual(rec.prior_failed, 1)


class TestAdoptStampsCachedAttempts(unittest.TestCase):
    def test_adopted_vm_gets_attempt_from_cached_scan(self):
        import tempfile, os, time
        from clock import Clock
        from model import StatusModel
        from feed import FeedWriter
        from logtail import LogTailer
        from vbox import VBoxPoller
        from guestpool import GuestProbePool
        from collector import Collector

        with tempfile.TemporaryDirectory() as root:
            pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
            open(os.path.join(pdir, "core.yml"), "w").write(
                "components:\n  - dc1\n  - ca1\n  - web1\n")
            # prior run where ca1 failed; web1 has no prior-failure history
            old = os.path.join(root, "20260702-100000"); os.makedirs(old + "/buildmon")
            open(old + "/buildmon/status.json", "w").write(
                '{"build":{"profile":"core"},"vms":{"ca1":{"state":"failed"}}}')
            open(old + "/ca1.log", "w").write("TASK [x] ***\nchanged: [ca1]\n")
            # live run: dc1 is tracked from the start; ca1/web1 only have
            # Phase-1 create-logs so far (not yet in tailers/model)
            cur = os.path.join(root, "20260702-120000"); os.makedirs(cur)
            open(cur + "/dc1.log", "w").write("TASK [y] ***\n")
            open(cur + "/ca1-create.log", "w").close()
            open(cur + "/web1-create.log", "w").close()
            clock = Clock()
            model = StatusModel("core", cur, time.time(), clock)
            model.add_vm("dc1", order_index=0)
            outdir = os.path.join(cur, "buildmon"); os.makedirs(outdir)
            col = Collector(cur, "core", model, feed=FeedWriter(outdir),
                            tailers={"dc1": LogTailer(cur + "/dc1.log", clock)},
                            vboxpoller=VBoxPoller({}, clock=clock),
                            guestpool=GuestProbePool({}, clock=clock, enabled=False),
                            clock=clock, profiles_dir=pdir, logger=lambda m: None)

            # profile known at construction: scan runs and caches attempts
            # for every stem visible in the logdir, including untracked ones
            col.load_attempts_and_stamp()
            self.assertNotIn("ca1", col.tailers)
            self.assertNotIn("web1", col.tailers)
            self.assertEqual(col._attempts["ca1"]["attempt"], 2)
            self.assertEqual(col._attempts.get("web1", {}).get("attempt", 1), 1)

            # provisioning now starts for both — real <vm>.log files appear
            open(cur + "/ca1.log", "w").write("TASK [z] ***\nchanged: [ca1]\n")
            open(cur + "/web1.log", "w").write("TASK [z] ***\nchanged: [web1]\n")
            col._adopt_new_logs()

            ca1_rec = model.get_vm("ca1")
            self.assertIsNotNone(ca1_rec)
            self.assertEqual(ca1_rec.attempt, 2)
            self.assertEqual(ca1_rec.prior_failed, 1)

            # control: an adopted VM with no prior failures stays at attempt 1
            web1_rec = model.get_vm("web1")
            self.assertIsNotNone(web1_rec)
            self.assertEqual(web1_rec.attempt, 1)


class TestAttemptScanFailsOpen(unittest.TestCase):
    def test_scan_error_degrades_to_empty_and_does_not_raise(self):
        import tempfile, os, time
        from unittest.mock import patch
        from clock import Clock
        from model import StatusModel
        from feed import FeedWriter
        from logtail import LogTailer
        from vbox import VBoxPoller
        from guestpool import GuestProbePool
        from collector import Collector
        import history

        with tempfile.TemporaryDirectory() as root:
            pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
            open(os.path.join(pdir, "core.yml"), "w").write("components:\n  - dc1\n")
            cur = os.path.join(root, "20260702-120000"); os.makedirs(cur)
            open(cur + "/dc1.log", "w").write("TASK [y] ***\n")
            clock = Clock()
            model = StatusModel("core", cur, time.time(), clock)
            model.add_vm("dc1", order_index=0)
            outdir = os.path.join(cur, "buildmon"); os.makedirs(outdir)
            col = Collector(cur, "core", model, feed=FeedWriter(outdir),
                            tailers={"dc1": LogTailer(cur + "/dc1.log", clock)},
                            vboxpoller=VBoxPoller({}, clock=clock),
                            guestpool=GuestProbePool({}, clock=clock, enabled=False),
                            clock=clock, profiles_dir=pdir, logger=lambda m: None)

            with patch("history.scan_attempts", side_effect=RuntimeError("boom")):
                col.load_attempts_and_stamp()  # must not raise

            self.assertEqual(col._attempts, {})
            rec = model.get_vm("dc1")
            self.assertEqual(rec.attempt, 1)


class TestRebootSignalFusion(unittest.TestCase):
    def _collector(self):
        import tempfile, os, time
        from clock import Clock
        from model import StatusModel
        from feed import FeedWriter
        from vbox import VBoxPoller
        from guestpool import GuestProbePool
        from collector import Collector
        root = tempfile.mkdtemp()
        cur = os.path.join(root, "20260706-120000"); os.makedirs(cur + "/buildmon")
        clock = Clock()
        model = StatusModel("core", cur, time.time(), clock)
        model.add_vm("dc1", order_index=0)
        col = Collector(cur, "core", model, feed=FeedWriter(cur + "/buildmon"),
                        tailers={}, vboxpoller=VBoxPoller({}, clock=clock),
                        guestpool=GuestProbePool({}, clock=clock, enabled=False),
                        clock=clock, logger=lambda m: None)
        return col

    def test_flap_then_lastboot_in_one_window_counts_once(self):
        col = self._collector()
        # window opens; guest goes dark
        n = col._note_reboot_signals("dc1", "rebooting", {"reachable": False, "last_boot": None}, False)
        self.assertEqual(n, 0)
        # flap: back up -> first signal counts
        n = col._note_reboot_signals("dc1", "rebooting", {"reachable": True, "last_boot": None}, False)
        self.assertEqual(n, 1)
        # last_boot advance lands in the SAME window -> no double count
        n = col._note_reboot_signals("dc1", "rebooting", {"reachable": True, "last_boot": "2026-07-06T12:05:00"}, False)
        self.assertEqual(n, 0)

    def test_lastboot_advance_outside_window_counts(self):
        col = self._collector()
        n = col._note_reboot_signals("dc1", "provisioning", {"reachable": True, "last_boot": "2026-07-06T11:00:00"}, False)
        self.assertEqual(n, 0)  # baseline only
        n = col._note_reboot_signals("dc1", "provisioning", {"reachable": True, "last_boot": "2026-07-06T12:00:00"}, False)
        self.assertEqual(n, 1)  # unexpected reboot
        n = col._note_reboot_signals("dc1", "provisioning", {"reachable": True, "last_boot": "2026-07-06T12:00:00"}, False)
        self.assertEqual(n, 0)  # same value, no re-count

    def test_vbox_edge_within_window_dedups(self):
        col = self._collector()
        n = col._note_reboot_signals("dc1", "rebooting", None, True)
        self.assertEqual(n, 1)
        n = col._note_reboot_signals("dc1", "rebooting", {"reachable": True, "last_boot": None}, True)
        self.assertEqual(n, 0)

    def test_no_guest_data_no_window_no_count(self):
        col = self._collector()
        self.assertEqual(col._note_reboot_signals("dc1", "provisioning", None, False), 0)


class TestAlertWiring(unittest.TestCase):
    def test_vm_failed_transition_dispatches_once(self):
        import alerts
        fired = []
        disp = alerts.AlertDispatcher("cmd", runner=lambda c, p: fired.append(p),
                                      logger=lambda m: None)
        col = TestRebootSignalFusion._collector(TestRebootSignalFusion())
        col.alerts = disp
        col._dispatch_alerts({"dc1": "failed"}, "parallel-provision")
        col._dispatch_alerts({"dc1": "failed"}, "parallel-provision")  # dedup
        self.assertEqual(len(fired), 1)
        import json
        self.assertEqual(json.loads(fired[0])["event"], "vm_failed")

    def test_build_done_phase_dispatches(self):
        import alerts, json
        fired = []
        disp = alerts.AlertDispatcher("cmd", runner=lambda c, p: fired.append(p),
                                      logger=lambda m: None)
        col = TestRebootSignalFusion._collector(TestRebootSignalFusion())
        col.alerts = disp
        col._dispatch_alerts({"dc1": "done"}, "done")
        events = [json.loads(p)["event"] for p in fired]
        self.assertIn("build_done", events)


class TestPidfilePickup(unittest.TestCase):
    """up.sh writes <logdir>/<vm>.pid alongside its per-VM log when it
    backgrounds a provision job (launch_vm/restore_vm/rebuild/dc1-overlap).
    The collector must read it fresh each tick (not just at construction) so
    a PID that appears after buildmon attaches — the common case, since
    buildmon is routinely started mid-build — is still picked up, and a
    rebuild's fresh PID replaces a stale one without restarting the collector."""

    def _collector(self, logdir, pid_map=None):
        from clock import FakeClock
        from model import StatusModel
        from feed import FeedWriter
        clk = FakeClock(1000.0)
        with open(os.path.join(logdir, "dc1.log"), "w") as fh:
            fh.write("TASK [x] ***\nchanged: [dc1]\n")
        model = StatusModel("core", logdir, 1000.0, clk)
        model.add_vm("dc1", order_index=0)
        col = Collector(logdir, "core", model, feed=FeedWriter(os.path.join(logdir, "buildmon")),
                        tailers={"dc1": LogTailer(os.path.join(logdir, "dc1.log"), clk)},
                        vboxpoller=_StubVbox(), guestpool=_StubPool(), clock=clk,
                        pid_map=pid_map)
        return col, clk

    def test_pidfile_present_before_construction_is_alive(self):
        with tempfile.TemporaryDirectory() as logdir:
            with open(os.path.join(logdir, "dc1.pid"), "w") as fh:
                fh.write(str(os.getpid()))
            col, clk = self._collector(logdir)
            col.tick(clk.now())
            snap = json.load(open(os.path.join(logdir, "buildmon", "status.json")))
            self.assertEqual(snap["vms"]["dc1"]["pid"], os.getpid())
            self.assertTrue(snap["vms"]["dc1"]["pid_alive"])

    def test_dead_pid_in_pidfile_is_not_alive(self):
        with tempfile.TemporaryDirectory() as logdir:
            dead = subprocess.Popen(["true"])
            dead.wait()
            with open(os.path.join(logdir, "dc1.pid"), "w") as fh:
                fh.write(str(dead.pid))
            col, clk = self._collector(logdir)
            col.tick(clk.now())
            snap = json.load(open(os.path.join(logdir, "buildmon", "status.json")))
            self.assertFalse(snap["vms"]["dc1"]["pid_alive"])

    def test_no_pidfile_falls_back_to_constructor_pid_map(self):
        with tempfile.TemporaryDirectory() as logdir:
            col, clk = self._collector(logdir, pid_map={"dc1": os.getpid()})
            col.tick(clk.now())
            snap = json.load(open(os.path.join(logdir, "buildmon", "status.json")))
            self.assertEqual(snap["vms"]["dc1"]["pid"], os.getpid())
            self.assertTrue(snap["vms"]["dc1"]["pid_alive"])

    def test_pidfile_appearing_after_first_tick_is_picked_up_next_tick(self):
        with tempfile.TemporaryDirectory() as logdir:
            col, clk = self._collector(logdir)
            col.tick(clk.now())
            snap1 = json.load(open(os.path.join(logdir, "buildmon", "status.json")))
            self.assertIsNone(snap1["vms"]["dc1"]["pid_alive"])
            with open(os.path.join(logdir, "dc1.pid"), "w") as fh:
                fh.write(str(os.getpid()))
            clk.advance(5)
            col.tick(clk.now())
            snap2 = json.load(open(os.path.join(logdir, "buildmon", "status.json")))
            self.assertEqual(snap2["vms"]["dc1"]["pid"], os.getpid())
            self.assertTrue(snap2["vms"]["dc1"]["pid_alive"])

    def test_garbage_pidfile_does_not_raise(self):
        with tempfile.TemporaryDirectory() as logdir:
            with open(os.path.join(logdir, "dc1.pid"), "w") as fh:
                fh.write("not-a-pid")
            col, clk = self._collector(logdir)
            col.tick(clk.now())  # must not raise
            snap = json.load(open(os.path.join(logdir, "buildmon", "status.json")))
            self.assertIsNone(snap["vms"]["dc1"]["pid_alive"])


if __name__ == "__main__":
    unittest.main()


class TestAdoptionWiresProber(unittest.TestCase):
    def test_adopted_vm_gets_prober_from_factory(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
            with open(os.path.join(pdir, "core.yml"), "w") as fh:
                fh.write("components:\n  - dc1\n  - ca1\n")
            d = os.path.join(root, "logs"); os.makedirs(d)
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("core", d, 1000.0, clk)
            pool = _StubPool()
            wired = []
            def factory(vm, prof):
                wired.append((vm, prof))
                return object()
            col = Collector(d, "core", model, FeedWriter(outdir),
                            tailers={}, vboxpoller=_StubVbox(), guestpool=pool,
                            clock=clk, pid_map={}, profiles_dir=pdir,
                            prober_factory=factory)
            with open(os.path.join(d, "ca1.log"), "w") as fh:
                fh.write("TASK [subordinate_ca : Install CA] ***\nchanged: [ca1]\n")
            col.tick(clk.now())
            self.assertIn(("ca1", "core"), wired)
            self.assertTrue(pool.has("ca1"))
            # second tick: already wired, factory not called again
            n = len(wired)
            col.tick(clk.now())
            self.assertEqual(len(wired), n)

    def test_late_inference_wires_probers_for_all_tracked(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
            with open(os.path.join(pdir, "small.yml"), "w") as fh:
                fh.write("components:\n  - dc1\n  - web1\n")
            with open(os.path.join(pdir, "pqc.yml"), "w") as fh:
                fh.write("components:\n  - dc1\n  - web1\n  - rootca-pqc\n")
            d = os.path.join(root, "logs"); os.makedirs(d)
            outdir = os.path.join(d, "buildmon")
            clk = FakeClock(1000.0)
            model = StatusModel("unknown", d, 1000.0, clk)
            pool = _StubPool()
            col = Collector(d, None, model, FeedWriter(outdir),
                            tailers={}, vboxpoller=_StubVbox(), guestpool=pool,
                            clock=clk, pid_map={}, profiles_dir=pdir,
                            prober_factory=lambda vm, prof: object())
            open(os.path.join(d, "dc1-create.log"), "w").close()
            col.tick(clk.now())
            self.assertFalse(pool.has("dc1"))     # no profile yet → dark
            open(os.path.join(d, "web1-create.log"), "w").close()
            open(os.path.join(d, "rootca-pqc-create.log"), "w").close()
            clk.advance(5)
            col.tick(clk.now())                    # unique superset → 'pqc'
            self.assertEqual(col.profile, "pqc")
            for vm in ("dc1", "web1", "rootca-pqc"):
                self.assertTrue(pool.has(vm), vm)
