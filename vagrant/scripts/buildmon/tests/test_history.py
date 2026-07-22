import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import history  # noqa: E402


def _mkdirs(root, *names):
    for n in names:
        os.makedirs(os.path.join(root, n), exist_ok=True)


class TestHistoryEnumeration(unittest.TestCase):
    def test_logdir_re_matches_timestamp_dirs_only(self):
        self.assertTrue(history.LOGDIR_RE.match("20260702-125121"))
        self.assertFalse(history.LOGDIR_RE.match("dead-20260702-125758"))
        self.assertFalse(history.LOGDIR_RE.match("ansible.log"))

    def test_sibling_logdirs_older_newest_first(self):
        with tempfile.TemporaryDirectory() as root:
            _mkdirs(root, "20260702-100000", "20260702-110000",
                    "20260702-120000", "20260702-130000", "dead-20260702-090000", ".buildmon")
            cur = os.path.join(root, "20260702-120000")
            got = history.sibling_logdirs(cur)
            # Should return older dirs (strictly e < base), newest-first
            self.assertEqual(got, ["20260702-110000", "20260702-100000"])
            # Explicitly verify newer sibling is NOT included
            self.assertNotIn("20260702-130000", got)

    def test_sibling_logdirs_cap(self):
        with tempfile.TemporaryDirectory() as root:
            names = [f"20260702-1200{i:02d}" for i in range(40)]
            _mkdirs(root, *names)
            cur = os.path.join(root, "20260702-120039")
            got = history.sibling_logdirs(cur, cap=5)
            self.assertEqual(len(got), 5)
            self.assertEqual(got[0], "20260702-120038")

    def test_reset_marker_roundtrip(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(history.read_reset_cutoff(root, "pqc-full"))
            p = history.write_reset_marker(root, "pqc-full", "20260702-120000")
            self.assertTrue(os.path.isfile(p))
            self.assertEqual(history.read_reset_cutoff(root, "pqc-full"), "20260702-120000")
            self.assertIsNone(history.read_reset_cutoff(root, "full"))  # profile-scoped


def _write(root, logdir, name, text):
    d = os.path.join(root, logdir)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "w") as fh:
        fh.write(text)


_RECAP_OK = ("PLAY RECAP ***\n"
             "dc1 : ok=49 changed=0 unreachable=0 failed=0 skipped=29 rescued=0 ignored=0\n")
_RECAP_FAIL = ("PLAY RECAP ***\n"
               "ca1 : ok=25 changed=3 unreachable=1 failed=0 skipped=8 rescued=0 ignored=0\n")
_INTERRUPTED = ("TASK [common : Install PowerShell 7] ***\n"
                "changed: [manage1]\n"
                "TASK [gui_tools : Install desktop apps] ***\n")  # no recap


class TestHistoryClassify(unittest.TestCase):
    def test_status_json_success_shortcut(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000/buildmon", "status.json",
                   '{"vms":{"manage1":{"state":"done"}}}')
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)  # log says otherwise
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "manage1"),
                "success")

    def test_status_json_failed_shortcut(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000/buildmon", "status.json",
                   '{"vms":{"ca1":{"state":"failed"}}}')
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "ca1"),
                "failed")

    def test_status_json_inconclusive_falls_through_to_log(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000/buildmon", "status.json",
                   '{"vms":{"manage1":{"state":"provisioning"}}}')  # collector died
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "manage1"),
                "interrupted")

    def test_log_clean_recap_is_success(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000", "dc1.log", _RECAP_OK)
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "dc1"), "success")

    def test_log_recap_with_unreachable_is_failed(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000", "ca1.log", _RECAP_FAIL)
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "ca1"), "failed")

    def test_log_tasks_no_recap_is_interrupted(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "manage1"),
                "interrupted")

    def test_no_log_is_none(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "20260702-100000"))
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "manage1"), "none")

    def test_create_log_only_is_none(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000", "manage1-create.log", "boot error\n")
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "manage1"), "none")

    def test_log_recap_with_failed_is_failed(self):
        with tempfile.TemporaryDirectory() as root:
            recap = ("PLAY RECAP ***\n"
                     "issueca : ok=30 changed=5 unreachable=0 failed=2 skipped=3 rescued=0 ignored=0\n")
            _write(root, "20260702-100000", "issueca.log", recap)
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "issueca"), "failed")

    def test_malformed_status_json_falls_through_to_log(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000/buildmon", "status.json", "{not valid json")
            _write(root, "20260702-100000", "manage1.log", _RECAP_OK)
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "manage1"), "success")

    def test_non_dict_status_json_falls_through_to_log(self):
        with tempfile.TemporaryDirectory() as root:
            _write(root, "20260702-100000/buildmon", "status.json", "[]")
            _write(root, "20260702-100000", "manage1.log", _RECAP_OK)
            self.assertEqual(
                history.classify_run(os.path.join(root, "20260702-100000"), "manage1"), "success")


class TestScanAttempts(unittest.TestCase):
    def _profiles_dir(self, root):
        pdir = os.path.join(root, "profiles")
        os.makedirs(pdir, exist_ok=True)
        with open(os.path.join(pdir, "pqc-full.yml"), "w") as fh:
            fh.write("components:\n  - dc1\n  - manage1\n")
        with open(os.path.join(pdir, "full.yml"), "w") as fh:
            fh.write("components:\n  - dc1\n  - ca1\n")
        return pdir

    def test_fresh_lab_attempt_one(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = self._profiles_dir(root)
            _write(root, "20260702-120000", "manage1.log", _INTERRUPTED)
            r = history.scan_attempts(os.path.join(root, "20260702-120000"),
                                      "pqc-full", profiles_dir=pdir)
            self.assertEqual(r["manage1"]["attempt"], 1)

    def test_one_prior_failure(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = self._profiles_dir(root)
            _write(root, "20260702-100000/buildmon", "status.json",
                   '{"vms":{"manage1":{"state":"failed"}}}')
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)
            _write(root, "20260702-100000", "dc1.log", _RECAP_OK)
            _write(root, "20260702-120000", "manage1.log", _INTERRUPTED)
            r = history.scan_attempts(os.path.join(root, "20260702-120000"),
                                      "pqc-full", profiles_dir=pdir)
            self.assertEqual(r["manage1"]["attempt"], 2)
            self.assertEqual(r["manage1"]["prior"], {"failed": 1, "interrupted": 0})

    def test_interrupt_and_failure_the_0702_shape(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = self._profiles_dir(root)
            _write(root, "20260702-090000", "manage1.log", _INTERRUPTED)      # interrupted
            _write(root, "20260702-100000/buildmon", "status.json",
                   '{"vms":{"manage1":{"state":"failed"}}}')                   # failed
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)
            _write(root, "20260702-120000", "manage1.log", _INTERRUPTED)      # live
            r = history.scan_attempts(os.path.join(root, "20260702-120000"),
                                      "pqc-full", profiles_dir=pdir)
            self.assertEqual(r["manage1"]["attempt"], 3)
            self.assertEqual(r["manage1"]["prior"], {"failed": 1, "interrupted": 1})

    def test_success_resets_walk(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = self._profiles_dir(root)
            _write(root, "20260702-080000", "manage1.log", _INTERRUPTED)  # older fail — masked
            _write(root, "20260702-090000", "manage1.log", _RECAP_OK)     # success — stop
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)  # fail after success
            _write(root, "20260702-120000", "manage1.log", _INTERRUPTED)
            r = history.scan_attempts(os.path.join(root, "20260702-120000"),
                                      "pqc-full", profiles_dir=pdir)
            self.assertEqual(r["manage1"]["attempt"], 2)

    def test_foreign_profile_sibling_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = self._profiles_dir(root)
            # a 'full' run (dc1+ca1) failed manage1? no manage1 there — but a
            # full run with a manage1 log must still be skipped for pqc-full.
            _write(root, "20260702-100000/buildmon", "status.json",
                   '{"build":{"profile":"full"},"vms":{"manage1":{"state":"failed"}}}')
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)
            _write(root, "20260702-120000", "manage1.log", _INTERRUPTED)
            r = history.scan_attempts(os.path.join(root, "20260702-120000"),
                                      "pqc-full", profiles_dir=pdir)
            self.assertEqual(r["manage1"]["attempt"], 1)

    def test_reset_marker_hides_older(self):
        with tempfile.TemporaryDirectory() as root:
            pdir = self._profiles_dir(root)
            _write(root, "20260702-100000/buildmon", "status.json",
                   '{"vms":{"manage1":{"state":"failed"}}}')
            _write(root, "20260702-100000", "manage1.log", _INTERRUPTED)
            _write(root, "20260702-120000", "manage1.log", _INTERRUPTED)
            history.write_reset_marker(root, "pqc-full", "20260702-110000")
            r = history.scan_attempts(os.path.join(root, "20260702-120000"),
                                      "pqc-full", profiles_dir=pdir)
            self.assertEqual(r["manage1"]["attempt"], 1)  # 10:00 fail is before cutoff


if __name__ == "__main__":
    unittest.main()
