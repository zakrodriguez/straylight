import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from clock import FakeClock  # noqa: E402
from logtail import LogTailer  # noqa: E402

FIX = os.path.join(os.path.dirname(__file__), "fixtures")

class TestLogTailer(unittest.TestCase):
    def test_current_task_and_result(self):
        t = LogTailer(os.path.join(FIX, "dc1-sample.log"), FakeClock(0))
        s = t.read()
        self.assertTrue(s.exists)
        self.assertEqual(s.task_name, "domain_controller : Create Autoenrollment GPO")
        self.assertEqual(s.last_result, "changed")
        self.assertFalse(s.fatal_finish)

    def test_waitdep_task_visible(self):
        s = LogTailer(os.path.join(FIX, "web1-waitdep.log"), FakeClock(0)).read()
        self.assertEqual(s.task_name, "machine_cert : Wait for Root CA cert in trusted store")
        self.assertIsNone(s.last_result)

    def test_fatal_recap(self):
        s = LogTailer(os.path.join(FIX, "scanner1-failed.log"), FakeClock(0)).read()
        self.assertTrue(s.fatal_finish)
        self.assertEqual(s.recap_failed, 1)
        self.assertEqual(s.last_result, "fatal")

    def test_missing_file(self):
        s = LogTailer(os.path.join(FIX, "nope.log"), FakeClock(0)).read()
        self.assertFalse(s.exists)
        self.assertIsNone(s.task_name)

    def test_result_tallies(self):
        s = LogTailer(os.path.join(FIX, "dc1-sample.log"), FakeClock(0)).read()
        self.assertEqual(s.changed, 2)   # fixture has 2 changed: lines
        self.assertEqual(s.ok, 0)
        self.assertEqual(s.failed, 0)
        f = LogTailer(os.path.join(FIX, "scanner1-failed.log"), FakeClock(0)).read()
        self.assertEqual(f.failed, 1)    # one fatal: line
        self.assertEqual(f.changed, 0)


_ATTEMPT1_FAILED = """\
TASK [machine_cert : Wait for Root CA cert in trusted store] ***
fatal: [web1]: FAILED! => {"msg": "retries exhausted"}

PLAY RECAP *********************************************************************
web1                       : ok=44   changed=22   unreachable=0    failed=1

Ansible failed to complete successfully. Any error output should be
visible above. Please fix these errors and try again.
"""

_ATTEMPT2_CLEAN = """\
TASK [common : Detect Windows installation type] ***
ok: [web1]

TASK [machine_cert : Wait for Root CA cert in trusted store] ***
changed: [web1]

PLAY RECAP *********************************************************************
web1                       : ok=88   changed=25   unreachable=0    failed=0
"""

_ATTEMPT2_FAILED = """\
TASK [common : Detect Windows installation type] ***
ok: [web1]

TASK [web_server : Create PKI website] ***
fatal: [web1]: FAILED! => {"msg": "boom"}

PLAY RECAP *********************************************************************
web1                       : ok=3    changed=0    unreachable=0    failed=1
"""


class TestMultiAttemptLog(unittest.TestCase):
    """In-place `vagrant provision` reruns append a second attempt to the same
    log. The LAST attempt wins (#214): attempt 1's fatal markers must not
    shadow attempt 2's clean recap — that mislabelled a recovered VM as
    hung/failed and dragged the build phase to failed, surviving replay."""

    def _read(self, content):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
            fh.write(content)
            path = fh.name
        try:
            return LogTailer(path, FakeClock(0)).read()
        finally:
            os.unlink(path)

    def test_second_attempt_clean_recap_overrides_first_fatal(self):
        s = self._read(_ATTEMPT1_FAILED + _ATTEMPT2_CLEAN)
        self.assertFalse(s.fatal_finish)
        self.assertEqual(s.recap_failed, 0)
        self.assertEqual(s.last_result, "changed")
        # tallies are attempt-scoped: 1 ok + 1 changed from attempt 2 only
        self.assertEqual((s.ok, s.changed, s.failed), (1, 1, 0))

    def test_second_attempt_also_failed_stays_fatal(self):
        s = self._read(_ATTEMPT1_FAILED + _ATTEMPT2_FAILED)
        self.assertTrue(s.fatal_finish)
        self.assertEqual(s.recap_failed, 1)
        self.assertEqual(s.failed, 1)

    def test_single_failed_attempt_unchanged(self):
        s = self._read(_ATTEMPT1_FAILED)
        self.assertTrue(s.fatal_finish)
        self.assertEqual(s.recap_failed, 1)

    def test_second_attempt_in_progress_not_failed(self):
        # rerun has started but no recap yet — the VM is provisioning again,
        # not stuck in attempt 1's failure
        in_progress = "TASK [common : Detect Windows installation type] ***\nok: [web1]\n"
        s = self._read(_ATTEMPT1_FAILED + in_progress)
        self.assertFalse(s.fatal_finish)
        self.assertIsNone(s.recap_failed)


if __name__ == "__main__":
    unittest.main()


class TestOkTallyFixture(unittest.TestCase):
    def test_ok_lines_tallied(self):
        # The dc1-sample fixture has zero ok: lines, so the ok-tally path was
        # only ever asserted at 0 — this fixture exercises the real mix.
        s = LogTailer(os.path.join(FIX, "manage1-okmix.log"), FakeClock(0)).read()
        self.assertEqual((s.ok, s.changed, s.failed), (3, 1, 0))
        self.assertEqual(s.last_result, "ok")
        self.assertEqual(s.task_name, "rsat : Verify tooling")
        self.assertFalse(s.fatal_finish)
