import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import capture  # noqa: E402

class TestExtract(unittest.TestCase):
    def test_single_value(self):
        b, e = capture.extract([{"name": "RequestId",
                                 "pattern": r"RequestID=([0-9A-Fa-f]+)"}],
                                "Re-issued: RequestID=2a SerialNumber=1f00")
        self.assertEqual(b, {"RequestId": "2a"})
        self.assertEqual(e, [])

    def test_multiple_values(self):
        caps = [{"name": "RequestId", "pattern": r"RequestID=([0-9A-Fa-f]+)"},
                {"name": "SerialNumber", "pattern": r"SerialNumber=([0-9A-Fa-f]+)"}]
        b, e = capture.extract(caps, "RequestID=2a SerialNumber=1f00")
        self.assertEqual(b, {"RequestId": "2a", "SerialNumber": "1f00"})
        self.assertEqual(e, [])

    def test_no_match_reports_error_and_no_binding(self):
        b, e = capture.extract([{"name": "X", "pattern": r"NOPE=(\d+)"}],
                               "nothing here")
        self.assertEqual(b, {})
        self.assertEqual(len(e), 1)
        self.assertIn("X", e[0])

    def test_empty_captures_is_noop(self):
        self.assertEqual(capture.extract([], "anything"), ({}, []))
        self.assertEqual(capture.extract(None, "anything"), ({}, []))

    def test_optional_group_not_participating_is_a_failure(self):
        # Pattern matches ("foo") but the optional group captured nothing ->
        # no value, so it must be reported as a failed capture, not bound to None.
        b, e = capture.extract([{"name": "X", "pattern": r"foo(bar)?"}], "foo")
        self.assertEqual(b, {})
        self.assertEqual(len(e), 1)
        self.assertIn("X", e[0])

if __name__ == "__main__":
    unittest.main()
