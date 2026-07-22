import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from logtail import LogState  # noqa: E402
import phase  # noqa: E402

class TestPhase(unittest.TestCase):
    def test_booting_when_no_log(self):
        s = phase.derive_vm_state("pending", LogState(exists=False), "running", None, False, 0, 600)
        self.assertEqual(s, "booting")

    def test_failed_on_recap(self):
        ls = LogState(exists=True, fatal_finish=True, recap_failed=1, last_result="fatal")
        self.assertEqual(phase.derive_vm_state("provisioning", ls, "running", True, False, 0, 600), "failed")

    def test_hung_when_fatal_and_idle(self):
        ls = LogState(exists=True, fatal_finish=True, recap_failed=1)
        self.assertEqual(phase.derive_vm_state("failed", ls, "running", True, False, 700, 600), "hung")

    def test_rebooting(self):
        ls = LogState(exists=True, task_name="domain_controller : Reboot after promo")
        self.assertEqual(phase.derive_vm_state("provisioning", ls, "poweroff", True, False, 0, 600), "rebooting")

    def test_done_without_pid_when_recap_clean(self):
        ls = LogState(exists=True, recap_failed=0, last_result="ok")
        self.assertEqual(phase.derive_vm_state("provisioning", ls, "running", None, False, 0, 600), "done")

    def test_not_done_while_pid_alive(self):
        ls = LogState(exists=True, recap_failed=0, last_result="ok")
        self.assertEqual(phase.derive_vm_state("provisioning", ls, "running", True, False, 0, 600), "provisioning")

    def test_waiting_dep(self):
        self.assertEqual(phase.detect_waiting_on("machine_cert : Wait for Root CA cert in trusted store"),
                         "ca1 root cert")
        self.assertIsNone(phase.detect_waiting_on("web_server : Install IIS"))

    def test_build_phase(self):
        self.assertEqual(phase.derive_build_phase({"dc1": "booting", "ca1": "pending"}, True), "creating")
        self.assertEqual(phase.derive_build_phase({"dc1": "provisioning", "ca1": "pending"}, True), "dc1-provision")
        self.assertEqual(phase.derive_build_phase(
            {"dc1": "done", "ca1": "provisioning", "web1": "provisioning"}, True), "parallel-provision")
        self.assertEqual(phase.derive_build_phase({"dc1": "done", "ca1": "done"}, True), "done")
        self.assertEqual(phase.derive_build_phase({"dc1": "failed", "ca1": "done"}, True), "failed")

class TestWarmReboot(unittest.TestCase):
    def _log(self, task="Reboot after domain join"):
        class L:
            exists = True
            fatal_finish = False
            recap_failed = None
            task_name = task
        return L()

    def test_reboot_task_with_stall_is_rebooting(self):
        st = phase.derive_vm_state("provisioning", self._log(), "running",
                                   True, False, stall_s=60, hang_threshold_s=600)
        self.assertEqual(st, "rebooting")

    def test_reboot_task_without_stall_stays_provisioning(self):
        st = phase.derive_vm_state("provisioning", self._log(), "running",
                                   True, False, stall_s=5, hang_threshold_s=600)
        self.assertEqual(st, "provisioning")

    def test_reboot_window_ceiling_falls_through(self):
        st = phase.derive_vm_state("rebooting", self._log(), "running",
                                   True, False, stall_s=700, hang_threshold_s=600)
        self.assertNotEqual(st, "rebooting")

    def test_non_reboot_task_stall_unaffected(self):
        st = phase.derive_vm_state("provisioning", self._log(task="Install IIS"),
                                   "running", True, False, stall_s=60,
                                   hang_threshold_s=600)
        self.assertEqual(st, "provisioning")

if __name__ == "__main__":
    unittest.main()


class TestDoneBeatsWaitingDep(unittest.TestCase):
    def test_clean_recap_on_wait_task_is_done_not_waiting(self):
        # A play can END cleanly while the last-seen task is a dependency
        # gate ("Wait for Root CA cert...") — e.g. manage1 self-healing when
        # the cert publishes inside its retry window. The recap is the
        # stronger signal: done, not waiting-dep forever.
        from logtail import LogState
        log = LogState(exists=True, recap_failed=0,
                       task_name="machine_cert : Wait for Root CA cert in trusted store")
        st = phase.derive_vm_state("waiting-dep", log, "running", pid_alive=False,
                                   reboot=False, stall_s=0, hang_threshold_s=600)
        self.assertEqual(st, "done")

    def test_wait_task_still_running_stays_waiting_dep(self):
        from logtail import LogState
        log = LogState(exists=True, recap_failed=None,
                       task_name="machine_cert : Wait for Root CA cert in trusted store")
        st = phase.derive_vm_state("provisioning", log, "running", pid_alive=True,
                                   reboot=False, stall_s=10, hang_threshold_s=600)
        self.assertEqual(st, "waiting-dep")
