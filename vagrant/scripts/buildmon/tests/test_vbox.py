import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from clock import FakeClock  # noqa: E402
import vbox  # noqa: E402

FIX = os.path.join(os.path.dirname(__file__), "fixtures")

def _read(name):
    with open(os.path.join(FIX, name)) as fh:
        return fh.read()

class TestVBox(unittest.TestCase):
    def test_parse_states(self):
        self.assertEqual(vbox.parse_showvminfo(_read("vbox-running.txt"))["vbox"], "running")
        self.assertEqual(vbox.parse_showvminfo(_read("vbox-poweroff.txt"))["vbox"], "poweroff")
        self.assertEqual(vbox.parse_showvminfo('VMState="frobnicated"')["vbox"], "unknown")

    def test_reboot_detection(self):
        p = vbox.VBoxPoller({"dc1": "straylight-core-dc1"}, clock=FakeClock(0))
        self.assertFalse(p.detect_reboot("dc1", "running", "poweroff"))
        self.assertTrue(p.detect_reboot("dc1", "poweroff", "running"))   # came back → reboot
        self.assertFalse(p.detect_reboot("dc1", "running", "running"))

    def test_poll_uses_injected_runner(self):
        calls = []
        def runner(args):
            calls.append(args)
            return _read("vbox-running.txt")
        p = vbox.VBoxPoller({"dc1": "straylight-core-dc1"}, runner=runner, clock=FakeClock(0))
        self.assertEqual(p.poll("dc1")["vbox"], "running")
        self.assertEqual(calls[0][0], "showvminfo")  # observer-only verb

if __name__ == "__main__":
    unittest.main()
