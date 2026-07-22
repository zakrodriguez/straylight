import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tui  # noqa: E402
from timefmt import parse_iso  # noqa: E402

SNAP = {
    "schema": "buildmon/v1",
    "build": {"profile": "core", "logdir": "logs/x", "phase": "dc1-provision",
              "started_at": "2026-07-01T20:00:00Z", "updated_at": "2026-07-01T20:14:00Z",
              "elapsed_s": 840, "counts": {"total": 4, "pending": 2, "running": 1, "done": 1,
                                           "failed": 0, "hung": 0}},
    "vms": {"dc1": {"state": "provisioning", "role": "domain_controller", "vbox": "running",
                    "pid": 412273, "pid_alive": True, "elapsed_s": 840,
                    "task": {"name": "domain_controller : Create Autoenrollment GPO",
                             "started_at": "2026-07-01T20:13:53Z", "duration_s": 7},
                    "result": {"last": "changed", "ok": 132, "changed": 47, "failed": 0},
                    "reboots": 1, "stall_s": 0, "waiting_on": None, "guest": None}},
}

class TestTui(unittest.TestCase):
    def test_render_plain_contains_key_signals(self):
        out = tui.render_plain(SNAP, events_tail=[{"ts": "2026-07-01T20:13:53Z", "vm": "dc1",
                                                   "kind": "task",
                                                   "name": "domain_controller : Create Autoenrollment GPO"}])
        self.assertIn("dc1-provision", out)
        self.assertIn("Create Autoenrollment GPO", out)   # THE blind-spot signal
        self.assertIn("reboots", out.lower())
        self.assertIn("1/4 done", out)   # render_plain emits f"{done}/{total} done"

    def test_load_feed_missing_is_graceful(self):
        with tempfile.TemporaryDirectory() as d:
            snap, evs = tui.load_feed(d)
            self.assertIsNone(snap)
            self.assertEqual(evs, [])

    def test_load_feed_reads_written(self):
        with tempfile.TemporaryDirectory() as d:
            outdir = os.path.join(d, "buildmon"); os.makedirs(outdir)
            json.dump(SNAP, open(os.path.join(outdir, "status.json"), "w"))
            open(os.path.join(outdir, "events.ndjson"), "w").write(
                json.dumps({"ts": "t", "kind": "phase", "from": None, "to": "creating"}) + "\n")
            snap, evs = tui.load_feed(d)
            self.assertEqual(snap["build"]["phase"], "dc1-provision")
            self.assertEqual(len(evs), 1)

    def test_guest_column(self):
        snap = json.loads(json.dumps(SNAP))
        snap["vms"]["dc1"]["guest"] = {"reachable": True, "note": None}
        out = tui.render_plain(snap, [])
        self.assertIn("GUEST", out)
        self.assertIn("up", out.split("\n")[4])      # dc1 row shows guest up
        out2 = tui.render_plain(SNAP, [])            # guest None → "-"
        self.assertIn("GUEST", out2)
        self.assertIn("dc1", out2.split("\n")[4])

    def test_age_marker(self):
        now = parse_iso(SNAP["build"]["updated_at"]) + 42
        out = tui.render_plain(SNAP, [], now_epoch=now)
        self.assertIn("(age 42s)", out)
        self.assertNotIn("age", tui.render_plain(SNAP, []))  # no now → no age

    def test_load_feed_skips_bad_event_lines(self):
        with tempfile.TemporaryDirectory() as d:
            outdir = os.path.join(d, "buildmon"); os.makedirs(outdir)
            with open(os.path.join(outdir, "status.json"), "w") as f:
                json.dump(SNAP, f)
            with open(os.path.join(outdir, "events.ndjson"), "w") as f:
                f.write('{"ts":"t","kind":"phase","to":"creating"}\nNOT-JSON\n{"ts":"t2","kind":"task","name":"x"}\n')
            snap, evs = tui.load_feed(d)
            self.assertEqual(len(evs), 2)   # bad line skipped, good ones kept


class TestTerminalStateDisplay(unittest.TestCase):
    def test_done_vm_blanks_dur_and_stall(self):
        snap = json.loads(json.dumps(SNAP))
        snap["vms"]["dc1"]["state"] = "done"
        snap["vms"]["dc1"]["stall_s"] = 1176
        out = tui.render_plain(snap, [])
        row = [l for l in out.splitlines() if l.startswith("dc1")][0]
        self.assertNotIn("1176", row)   # stall blanked once terminal
        self.assertNotIn("7s", row)     # duration blanked once terminal


class TestAttemptSuffix(unittest.TestCase):
    def _snap(self, vm_extra):
        vm = {"state": "provisioning", "role": None, "vbox": "running",
              "pid": None, "pid_alive": None, "elapsed_s": 5,
              "task": {"name": "t", "duration_s": 5}, "result": None,
              "reboots": 0, "stall_s": 0, "waiting_on": None, "guest": None}
        vm.update(vm_extra)
        return {"build": {"profile": "pqc-full", "phase": "parallel-provision",
                          "elapsed_s": 10, "updated_at": "2026-07-02T18:00:00Z",
                          "counts": {"total": 1, "done": 0, "running": 1,
                                     "pending": 0, "failed": 0, "hung": 0}},
                "vms": {"manage1": vm}}

    def test_suffix_present_when_attempt_gt_one(self):
        out = tui.render_plain(self._snap(
            {"attempt": 3, "prior": {"failed": 1, "interrupted": 1}}), [])
        row = [l for l in out.splitlines() if l.startswith("manage1")][0]
        self.assertIn("attempt 3: 1 failed, 1 interrupted", row)

    def test_no_suffix_when_first_attempt(self):
        out = tui.render_plain(self._snap({}), [])
        row = [l for l in out.splitlines() if l.startswith("manage1")][0]
        self.assertNotIn("attempt", row)

    def test_omits_zero_clause(self):
        out = tui.render_plain(self._snap(
            {"attempt": 2, "prior": {"failed": 0, "interrupted": 2}}), [])
        row = [l for l in out.splitlines() if l.startswith("manage1")][0]
        self.assertIn("attempt 2: 2 interrupted", row)
        self.assertNotIn("0 failed", row)


if __name__ == "__main__":
    unittest.main()
