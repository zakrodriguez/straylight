import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import companion  # noqa: E402

_STEPS = [{"step": "a", "host": "h", "command": "c", "expects": [],
           "rc": 0, "strict": False, "preamble": False}]

_GOOD = {
    "lab": "sample", "profile": "core",
    "parameters": {"CA": "X"},
    "normalizers": {"latency": {"pattern": r"\d+ ms", "placeholder": "<MS>"}},
    "steps": [{"step": "a", "host": "h", "command": "c", "rc": 0,
               "expect": [], "strict": False, "captured": "ok"}],
}

class TestCompanion(unittest.TestCase):
    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "sample.golden.yml")
            companion.dump(_GOOD, p)
            back = companion.load(p)
            self.assertEqual(back["lab"], "sample")
            self.assertEqual(back["parameters"]["CA"], "X")

    def test_validate_good(self):
        self.assertEqual(companion.validate(_GOOD, _STEPS), [])

    def test_validate_missing_step_entry(self):
        steps = _STEPS + [{"step": "b", "host": "h", "command": "c",
                           "expects": [], "rc": 0, "strict": False, "preamble": False}]
        probs = companion.validate(_GOOD, steps)
        self.assertTrue(any("b" in x for x in probs))

    def test_validate_orphan_companion_step(self):
        comp = dict(_GOOD)
        comp["steps"] = _GOOD["steps"] + [{"step": "z", "host": "h", "command": "c",
                                           "rc": 0, "expect": [], "strict": False,
                                           "captured": ""}]
        probs = companion.validate(comp, _STEPS)
        self.assertTrue(any("z" in x for x in probs))

    def test_validate_bad_normalizer(self):
        comp = dict(_GOOD)
        comp["normalizers"] = {"x": {"pattern": "p"}}  # missing placeholder
        self.assertTrue(companion.validate(comp, _STEPS))

    def test_validate_normalizers_not_a_mapping(self):
        comp = dict(_GOOD)
        comp["normalizers"] = ["not", "a", "dict"]
        probs = companion.validate(comp, _STEPS)
        self.assertTrue(any("normalizers must be a mapping" in p for p in probs))

if __name__ == "__main__":
    unittest.main()
