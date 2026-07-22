import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import vbox  # noqa: E402
from guest import GuestProber, ALLOWED_SSH  # noqa: E402

class TestNonInvasive(unittest.TestCase):
    def test_vbox_default_runner_rejects_mutating_verbs(self):
        with self.assertRaises(ValueError):
            vbox._default_runner(["controlvm", "x", "poweroff"])
        with self.assertRaises(ValueError):
            vbox._default_runner(["startvm", "x"])

    def test_guest_argv_is_from_allowlist(self):
        captured = []
        def runner(argv, timeout):
            captured.append(argv); return (0, "ok")
        GuestProber("acme1", "ssh", {"host": "acme1"}, runner=runner).probe()
        # the ssh command must be one of the read-only allowlisted strings
        self.assertTrue(any(cmd in " ".join(captured[0]) for cmd in ALLOWED_SSH))

    def test_no_vagrant_or_ansible_tokens_in_sources(self):
        # Static guard: the collector/vbox/guest modules must not shell out to vagrant/ansible.
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        for mod in ("collector.py", "vbox.py", "guest.py", "guestpool.py"):
            src = open(os.path.join(base, mod)).read()
            self.assertNotIn('"vagrant"', src)
            self.assertNotIn('"ansible"', src)

class TestWinrmProbeIsReadOnly(unittest.TestCase):
    def test_wsman_body_contains_only_enumerate_actions(self):
        import guest
        body = guest._WSMAN_ENUM_BODY
        self.assertIn("enumeration/Enumerate", body)
        for verb in ("shell/Create", "shell/Command", "shell/Signal",
                     "transfer/Create", "transfer/Delete", "transfer/Put"):
            self.assertNotIn(verb, body)

    def test_ssh_probe_command_is_allowlisted(self):
        import guest
        self.assertIn("uptime -s", guest.ALLOWED_SSH)


if __name__ == "__main__":
    unittest.main()
