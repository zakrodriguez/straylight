import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from enums import PHASES, VM_STATES, VBOX_STATES, EVENT_KINDS, is_valid  # noqa: E402

class TestEnums(unittest.TestCase):
    def test_expected_members(self):
        self.assertIn("dc1-provision", PHASES)
        self.assertIn("waiting-dep", VM_STATES)
        self.assertIn("aborted", VBOX_STATES)
        self.assertIn("reboot", EVENT_KINDS)

    def test_is_valid(self):
        self.assertTrue(is_valid("state", "hung"))
        self.assertFalse(is_valid("state", "bogus"))
        self.assertTrue(is_valid("event", "monitor"))

if __name__ == "__main__":
    unittest.main()
