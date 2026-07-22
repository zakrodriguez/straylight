import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import normalize  # noqa: E402

class TestNormalize(unittest.TestCase):
    def test_apply_replaces_all_named_rules(self):
        text = "alive (12 ms)\nSerial Number: 3af0091b"
        norms = {
            "latency": {"pattern": r"\d+ ms", "placeholder": "<MS>"},
            "serial": {"pattern": r"Serial Number: [0-9a-f]+", "placeholder": "<SERIAL>"},
        }
        out = normalize.apply(text, norms)
        self.assertIn("alive (<MS>)", out)
        self.assertIn("<SERIAL>", out)
        self.assertNotIn("3af0091b", out)

    def test_apply_empty_norms_is_identity(self):
        self.assertEqual(normalize.apply("x", {}), "x")

    def test_suggest_returns_matching_builtins_only(self):
        s = normalize.suggest("responded in 8 ms")
        self.assertIn("latency", s)
        self.assertEqual(s["latency"]["placeholder"], "<LATENCY>")
        # a GUID is not present -> not suggested
        self.assertNotIn("guid", s)

    def test_suggest_detects_guid(self):
        s = normalize.suggest("id 11111111-2222-3333-4444-555555555555 done")
        self.assertIn("guid", s)

    def test_latency_does_not_overmatch_inside_token(self):
        s = normalize.suggest("took 5msec to warm")
        self.assertNotIn("latency", s)   # '5msec' is not a latency reading
        s2 = normalize.suggest("took 5 ms flat")
        self.assertIn("latency", s2)     # real reading still matched

if __name__ == "__main__":
    unittest.main()
