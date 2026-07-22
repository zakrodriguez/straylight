import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import annotate  # noqa: E402

BASIC = '''# Lab
prose here
<!-- @verify host=manage1 step=ping-admin expect=/interface is alive/ rc=0 -->
```powershell
certutil -config $CA -ping
```
more prose
<!-- @verify host=lab step=rpc-reach -->
```bash
nc -zv 192.168.56.21 135 < /dev/null
```
'''

class TestParse(unittest.TestCase):
    def test_two_steps_parsed_in_order(self):
        steps = annotate.parse_lab(BASIC)
        self.assertEqual([s["step"] for s in steps], ["ping-admin", "rpc-reach"])
        self.assertEqual(steps[0]["host"], "manage1")
        self.assertEqual(steps[0]["command"], "certutil -config $CA -ping")
        self.assertEqual(steps[0]["expects"], ["interface is alive"])
        self.assertEqual(steps[0]["rc"], 0)
        self.assertFalse(steps[0]["strict"])
        self.assertFalse(steps[0]["preamble"])
        # rpc-reach has no expect/rc -> defaults
        self.assertEqual(steps[1]["expects"], [])
        self.assertEqual(steps[1]["rc"], 0)
        self.assertEqual(steps[1]["host"], "lab")

    def test_unannotated_block_ignored(self):
        md = "```powershell\nGet-Process\n```\n"
        self.assertEqual(annotate.parse_lab(md), [])

    def test_repeatable_expect(self):
        md = ('<!-- @verify host=h step=s expect=/a/ expect=/b/ -->\n'
              '```bash\ntrue\n```\n')
        self.assertEqual(annotate.parse_lab(md)[0]["expects"], ["a", "b"])

    def test_strict_and_preamble_flags(self):
        md = ('<!-- @verify host=h step=setup preamble=true -->\n```bash\nx=1\n```\n'
              '<!-- @verify host=h step=s strict=true -->\n```bash\ntrue\n```\n')
        steps = annotate.parse_lab(md)
        self.assertTrue(steps[0]["preamble"])
        self.assertTrue(steps[1]["strict"])

    def test_unknown_key_raises(self):
        md = '<!-- @verify host=h step=s bogus=1 -->\n```bash\ntrue\n```\n'
        with self.assertRaises(annotate.AnnotationError):
            annotate.parse_lab(md)

    def test_missing_host_raises(self):
        md = '<!-- @verify step=s -->\n```bash\ntrue\n```\n'
        with self.assertRaises(annotate.AnnotationError):
            annotate.parse_lab(md)

    def test_sentinel_without_fence_raises(self):
        md = '<!-- @verify host=h step=s -->\nplain prose, no fence\n'
        with self.assertRaises(annotate.AnnotationError):
            annotate.parse_lab(md)

    def test_duplicate_step_raises(self):
        md = ('<!-- @verify host=h step=dup -->\n```bash\ntrue\n```\n'
              '<!-- @verify host=h step=dup -->\n```bash\ntrue\n```\n')
        with self.assertRaises(annotate.AnnotationError):
            annotate.parse_lab(md)

    def test_non_integer_rc_raises(self):
        md = '<!-- @verify host=h step=s rc=abc -->\n```bash\ntrue\n```\n'
        with self.assertRaises(annotate.AnnotationError):
            annotate.parse_lab(md)

    def test_blank_lines_between_sentinel_and_fence_ok(self):
        md = '<!-- @verify host=h step=s -->\n\n\n```bash\ntrue\n```\n'
        steps = annotate.parse_lab(md)
        self.assertEqual(steps[0]["step"], "s")
        self.assertEqual(steps[0]["command"], "true")

    def test_missing_step_raises(self):
        md = '<!-- @verify host=h -->\n```bash\ntrue\n```\n'
        with self.assertRaises(annotate.AnnotationError):
            annotate.parse_lab(md)

    def test_non_boolean_strict_raises(self):
        md = '<!-- @verify host=h step=s strict=yes -->\n```bash\ntrue\n```\n'
        with self.assertRaises(annotate.AnnotationError):
            annotate.parse_lab(md)

    def test_capture_single_parsed(self):
        md = ("<!-- @verify host=issueca step=enroll capture=RequestId:/RequestID=([0-9A-Fa-f]+)/ -->\n"
              "```powershell\nrun\n```\n")
        steps = annotate.parse_lab(md)
        assert steps[0]["captures"] == [{"name": "RequestId",
                                         "pattern": r"RequestID=([0-9A-Fa-f]+)"}]

    def test_capture_absent_defaults_empty(self):
        md = "<!-- @verify host=manage1 step=s -->\n```powershell\nrun\n```\n"
        assert annotate.parse_lab(md)[0]["captures"] == []

    def test_capture_repeatable_and_spaces_in_regex(self):
        md = ("<!-- @verify host=manage1 step=s "
              "capture=A:/Original thumbprint bytes:\\s*([0-9A-F]+)/ "
              "capture=B:/RequestID=([0-9A-Fa-f]+)/ -->\n"
              "```powershell\nrun\n```\n")
        caps = annotate.parse_lab(md)[0]["captures"]
        assert [c["name"] for c in caps] == ["A", "B"]
        assert caps[0]["pattern"] == r"Original thumbprint bytes:\s*([0-9A-F]+)"

    def test_capture_rejects_no_group(self):
        md = "<!-- @verify host=m step=s capture=X:/nogroup/ -->\n```\nr\n```\n"
        try:
            annotate.parse_lab(md); assert False, "expected AnnotationError"
        except annotate.AnnotationError as e:
            assert "group" in str(e)

    def test_capture_rejects_bad_form(self):
        md = "<!-- @verify host=m step=s capture=noslashes -->\n```\nr\n```\n"
        try:
            annotate.parse_lab(md); assert False, "expected AnnotationError"
        except annotate.AnnotationError as e:
            assert "capture" in str(e).lower()

    def test_capture_rejects_uncompilable(self):
        md = "<!-- @verify host=m step=s capture=X:/([0-9/ -->\n```\nr\n```\n"
        try:
            annotate.parse_lab(md); assert False, "expected AnnotationError"
        except annotate.AnnotationError:
            pass

    def test_capture_rejects_duplicate_name_in_step(self):
        md = ("<!-- @verify host=m step=s capture=X:/(a)/ capture=X:/(b)/ -->\n"
              "```\nr\n```\n")
        try:
            annotate.parse_lab(md); assert False, "expected AnnotationError"
        except annotate.AnnotationError as e:
            assert "duplicate" in str(e).lower()

if __name__ == "__main__":
    unittest.main()
