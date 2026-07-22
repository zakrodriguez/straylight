import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from clock import FakeClock, Clock  # noqa: E402
from model import StatusModel  # noqa: E402

class TestStatusModel(unittest.TestCase):
    def setUp(self):
        self.clk = FakeClock(1000.0)
        self.m = StatusModel(profile="core", logdir="logs/x", started_epoch=1000.0, clock=self.clk)
        self.m.add_vm("dc1", role="domain_controller", order_index=0)
        self.m.add_vm("ca1", role="subordinate_ca", order_index=1)

    def test_snapshot_shape_and_counts(self):
        self.m.update_vm("dc1", state="provisioning", vbox="running",
                         task_name="domain_controller : Create Autoenrollment GPO",
                         task_start_epoch=1053.0, last_result="changed", ok=132, changed=47,
                         start_epoch=1000.0)
        snap = self.m.snapshot(now_epoch=1060.0)
        self.assertEqual(snap["schema"], "buildmon/v1")
        self.assertEqual(snap["build"]["profile"], "core")
        self.assertEqual(snap["build"]["phase"], "creating")
        self.assertEqual(snap["build"]["elapsed_s"], 60)
        self.assertEqual(snap["build"]["counts"]["total"], 2)
        self.assertEqual(snap["build"]["counts"]["running"], 1)   # dc1 provisioning
        self.assertEqual(snap["build"]["counts"]["pending"], 1)   # ca1
        dc1 = snap["vms"]["dc1"]
        self.assertEqual(dc1["state"], "provisioning")
        self.assertEqual(dc1["task"]["name"], "domain_controller : Create Autoenrollment GPO")
        self.assertEqual(dc1["task"]["duration_s"], 7)            # 1060 - 1053
        self.assertEqual(dc1["result"], {"last": "changed", "ok": 132, "changed": 47, "failed": 0})
        self.assertIsNone(snap["vms"]["ca1"]["task"])
        self.assertIsNone(dc1["guest"])

    def test_update_returns_changes_and_set_phase(self):
        changes = self.m.update_vm("dc1", state="booting")
        self.assertIn(("state", "pending", "booting"), changes)
        self.assertEqual(self.m.update_vm("dc1", state="booting"), [])  # no-op → empty changes list
        self.assertEqual(self.m.set_phase("dc1-provision"), ("creating", "dc1-provision"))
        self.assertIsNone(self.m.set_phase("dc1-provision"))

    def test_get_vm(self):
        rec = self.m.get_vm("dc1")
        self.assertIsNotNone(rec)
        self.assertEqual(rec.name, "dc1")
        self.assertIsNone(self.m.get_vm("does-not-exist"))

class TestAttemptFields(unittest.TestCase):
    def _model(self):
        from clock import Clock
        m = StatusModel("pqc-full", "/tmp/x", 1000.0, Clock())
        m.add_vm("manage1", order_index=0)
        return m

    def test_attempt_absent_when_one(self):
        m = self._model()
        snap = m.snapshot(1010.0)
        self.assertNotIn("attempt", snap["vms"]["manage1"])
        self.assertNotIn("prior", snap["vms"]["manage1"])

    def test_attempt_emitted_when_gt_one(self):
        m = self._model()
        m.update_vm("manage1", attempt=3, prior_failed=1, prior_interrupted=1)
        snap = m.snapshot(1010.0)
        self.assertEqual(snap["vms"]["manage1"]["attempt"], 3)
        self.assertEqual(snap["vms"]["manage1"]["prior"], {"failed": 1, "interrupted": 1})

if __name__ == "__main__":
    unittest.main()
