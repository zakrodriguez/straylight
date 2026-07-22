import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import alerts  # noqa: E402


class TestAlertDispatcher(unittest.TestCase):
    def _dispatcher(self, cmd="mycmd"):
        fired = []
        d = alerts.AlertDispatcher(cmd, runner=lambda c, payload: fired.append((c, payload)),
                                   logger=lambda m: None)
        return d, fired

    def test_dispatch_runs_cmd_with_json_payload(self):
        d, fired = self._dispatcher()
        ok = d.dispatch("vm_failed", "ca1", {"profile": "core", "state": "failed"})
        self.assertTrue(ok)
        cmd, payload = fired[0]
        self.assertEqual(cmd, "mycmd")
        data = json.loads(payload)
        self.assertEqual(data["event"], "vm_failed")
        self.assertEqual(data["vm"], "ca1")
        self.assertEqual(data["profile"], "core")
        self.assertIn("ts", data)

    def test_dedup_per_event_vm(self):
        d, fired = self._dispatcher()
        d.dispatch("vm_failed", "ca1", {})
        d.dispatch("vm_failed", "ca1", {})
        self.assertEqual(len(fired), 1)
        d.dispatch("vm_hung", "ca1", {})    # different event, fires
        d.dispatch("vm_failed", "web1", {})  # different vm, fires
        self.assertEqual(len(fired), 3)

    def test_no_cmd_is_inert(self):
        d, fired = self._dispatcher(cmd=None)
        self.assertFalse(d.dispatch("vm_failed", "ca1", {}))
        self.assertEqual(fired, [])

    def test_runner_exception_is_swallowed(self):
        logs = []
        def boom(cmd, payload):
            raise RuntimeError("hook exploded")
        d = alerts.AlertDispatcher("mycmd", runner=boom, logger=logs.append)
        self.assertTrue(d.dispatch("build_done", None, {}))  # dispatch itself survives
        self.assertTrue(any("hook exploded" in m or "RuntimeError" in m for m in logs))

    def test_build_events_use_null_vm(self):
        d, fired = self._dispatcher()
        d.dispatch("build_done", None, {})
        self.assertIsNone(json.loads(fired[0][1])["vm"])

    def test_json_serialization_failure_does_not_raise_and_is_not_marked_fired(self):
        d, fired = self._dispatcher()
        ok = d.dispatch("vm_failed", "ca1", {"bad": object()})
        self.assertFalse(ok)
        self.assertEqual(fired, [])
        # same (event, vm) key must still be eligible to fire once given valid data
        ok2 = d.dispatch("vm_failed", "ca1", {"profile": "core"})
        self.assertTrue(ok2)
        self.assertEqual(len(fired), 1)
        data = json.loads(fired[0][1])
        self.assertEqual(data["event"], "vm_failed")
        self.assertEqual(data["profile"], "core")

    def test_broken_logger_does_not_escape(self):
        def boom_runner(cmd, payload):
            raise RuntimeError("hook exploded")
        def boom_logger(msg):
            raise RuntimeError("logger exploded")
        d = alerts.AlertDispatcher("mycmd", runner=boom_runner, logger=boom_logger)
        try:
            ok = d.dispatch("vm_failed", "ca1", {})
        except Exception as exc:
            self.fail(f"dispatch() raised despite broken runner+logger: {exc!r}")
        self.assertTrue(ok)


if __name__ == "__main__":
    unittest.main()
