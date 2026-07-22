import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import gate  # noqa: E402

def _step(**kw):
    base = {"step": "s", "host": "h", "command": "c", "expects": [],
            "rc": 0, "strict": False, "preamble": False}
    base.update(kw)
    return base

class TestGate(unittest.TestCase):
    def test_pass_on_rc_and_expect(self):
        r = gate.evaluate(_step(expects=["interface is alive"]),
                          {"stdout": "... interface is alive (12 ms)", "rc": 0}, {})
        self.assertTrue(r["passed"])
        self.assertEqual(r["reasons"], [])

    def test_fail_on_rc_mismatch(self):
        r = gate.evaluate(_step(rc=0), {"stdout": "boom", "rc": 1}, {})
        self.assertFalse(r["passed"])
        self.assertTrue(any("exit code" in x for x in r["reasons"]))

    def test_fail_on_missing_expect_lists_the_regex(self):
        r = gate.evaluate(_step(expects=["alive", "reachable"]),
                          {"stdout": "alive only", "rc": 0}, {})
        self.assertFalse(r["passed"])
        self.assertTrue(any("reachable" in x for x in r["reasons"]))

    def test_expect_matched_after_normalization(self):
        # expect literally contains <MS>; only matches once latency normalized
        norms = {"latency": {"pattern": r"\d+ ms", "placeholder": "<MS>"}}
        r = gate.evaluate(_step(expects=["alive \\(<MS>\\)"]),
                          {"stdout": "alive (12 ms)", "rc": 0}, norms)
        self.assertTrue(r["passed"])

    def test_strict_diff_fails_on_change(self):
        r = gate.evaluate(_step(strict=True),
                          {"stdout": "line A\nline C", "rc": 0}, {},
                          golden={"captured": "line A\nline B"})
        self.assertFalse(r["passed"])
        self.assertTrue(any("strict" in x for x in r["reasons"]))

    def test_strict_diff_passes_when_equal_modulo_norms(self):
        norms = {"latency": {"pattern": r"\d+ ms", "placeholder": "<MS>"}}
        r = gate.evaluate(_step(strict=True),
                          {"stdout": "took 9 ms", "rc": 0}, norms,
                          golden={"captured": "took <MS>"})
        self.assertTrue(r["passed"])

if __name__ == "__main__":
    unittest.main()
