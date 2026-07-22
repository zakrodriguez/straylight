import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from feed import FeedWriter  # noqa: E402

def _snap(phase, dc1_state, task=None, reboots=0):
    return {"schema": "buildmon/v1",
            "build": {"phase": phase, "profile": "core", "logdir": "x",
                      "started_at": "2026-07-01T20:00:00Z", "updated_at": "2026-07-01T20:01:00Z",
                      "elapsed_s": 60, "counts": {}},
            "vms": {"dc1": {"state": dc1_state, "task": ({"name": task} if task else None),
                            "reboots": reboots, "waiting_on": None}}}

class TestFeed(unittest.TestCase):
    def test_atomic_status_write(self):
        with tempfile.TemporaryDirectory() as d:
            w = FeedWriter(d)
            w.write_status(_snap("creating", "pending"))
            with open(os.path.join(d, "status.json")) as fh:
                self.assertEqual(json.load(fh)["schema"], "buildmon/v1")
            self.assertFalse(any(f.endswith(".tmp") for f in os.listdir(d)))  # no temp left behind

    def test_transitions_emitted(self):
        with tempfile.TemporaryDirectory() as d:
            w = FeedWriter(d)
            s0 = _snap("creating", "booting")
            s1 = _snap("dc1-provision", "provisioning", task="T1")
            evs = w.emit_transitions(s0, s1, ts="2026-07-01T20:01:00Z")
            kinds = [e["kind"] for e in evs]
            self.assertIn("phase", kinds)
            self.assertIn("state", kinds)
            self.assertIn("task", kinds)
            lines = open(os.path.join(d, "events.ndjson")).read().strip().splitlines()
            self.assertEqual(len(lines), len(evs))
            self.assertEqual(json.loads(lines[0])["kind"], kinds[0])

    def test_reject_bad_event_kind(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                FeedWriter(d).append_event({"kind": "nope", "ts": "2026-07-01T20:00:00Z"})


class TestFeedPermissions(unittest.TestCase):
    def test_status_json_world_readable(self):
        import stat, tempfile
        with tempfile.TemporaryDirectory() as d:
            w = FeedWriter(d)
            w.write_status({"schema": "buildmon/v1", "build": {}, "vms": {}})
            mode = stat.S_IMODE(os.stat(os.path.join(d, "status.json")).st_mode)
            self.assertEqual(mode, 0o644)


if __name__ == "__main__":
    unittest.main()
