import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import harness, runner, companion  # noqa: E402

FIX = os.path.join(os.path.dirname(__file__), "fixtures")

def _resolver(vm, profile, root):
    return {"available": True, "transport": "winrm", "vm": vm}

class TestHarness(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(FIX, "sample-lab.md")) as fh:
            self.md = fh.read()
        self.comp = companion.load(os.path.join(FIX, "sample-lab.golden.yml"))

    def test_lint_clean_fixture(self):
        r = runner.StepRunner("core", "/root", exec_fn=lambda *a: (0, ""),
                              resolver=_resolver)
        self.assertEqual(harness.lint(self.md, self.comp, r), [])

    def test_lint_flags_unresolved_param(self):
        broken = dict(self.comp); broken["parameters"] = {}
        r = runner.StepRunner("core", "/root", exec_fn=lambda *a: (0, ""),
                              resolver=_resolver)
        probs = harness.lint(self.md, broken, r)
        self.assertTrue(any("CA" in x for x in probs))

    def test_check_all_pass(self):
        def good_exec(transport, host, script):
            return (0, "Server interface is alive (7 ms)")
        r = runner.StepRunner("core", "/root", exec_fn=good_exec, resolver=_resolver)
        out = harness.check(self.md, self.comp, r)
        self.assertTrue(out["passed"])
        self.assertTrue(all(x["passed"] for x in out["results"]))

    def test_check_reports_failure_but_continues(self):
        def bad_exec(transport, host, script):
            return (1, "RPC server unavailable")
        r = runner.StepRunner("core", "/root", exec_fn=bad_exec, resolver=_resolver)
        out = harness.check(self.md, self.comp, r)
        self.assertFalse(out["passed"])
        self.assertEqual(len(out["results"]), len(self.comp["steps"]))

    def test_check_gates_on_companion_expect_not_annotated_default(self):
        # Annotated sentinel says expect=/NEVER-IN-OUTPUT/; the companion
        # overrides expect to ["hello-world"]. Live output is "hello-world".
        # A CORRECT bridge gates on the companion value -> PASS.
        # A BROKEN bridge (gating on the annotated default) -> would FAIL.
        # So asserting passed==True proves the bridge uses the companion value.
        md = ("<!-- @verify host=manage1 step=s expect=/NEVER-IN-OUTPUT/ -->\n"
              "```powershell\nrun\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {}, "normalizers": {},
                "steps": [{"step": "s", "host": "manage1", "command": "run",
                           "rc": 0, "expect": ["hello-world"], "strict": False,
                           "captured": ""}]}
        r = runner.StepRunner("core", "/root",
                              exec_fn=lambda t, h, script: (0, "hello-world"),
                              resolver=_resolver)
        out = harness.check(md, comp, r)
        self.assertTrue(out["passed"])
        self.assertTrue(out["results"][0]["passed"])

    def test_check_strict_gates_on_companion_captured(self):
        # strict=true step: check() must feed the companion's captured as the
        # golden for the full-diff. Live output differing from golden -> FAIL;
        # matching -> PASS. Exercises the strict branch (never hit before).
        md = "<!-- @verify host=manage1 step=s -->\n```powershell\nrun\n```\n"
        def comp(strict_capture):
            return {"lab": "x", "profile": "core", "parameters": {}, "normalizers": {},
                    "steps": [{"step": "s", "host": "manage1", "command": "run",
                               "rc": 0, "expect": [], "strict": True,
                               "captured": strict_capture}]}
        r_diff = runner.StepRunner("core", "/root",
                                   exec_fn=lambda t, h, script: (0, "DIFFERENT LINE"),
                                   resolver=_resolver)
        self.assertFalse(harness.check(md, comp("GOLDEN LINE"), r_diff)["passed"])
        r_same = runner.StepRunner("core", "/root",
                                   exec_fn=lambda t, h, script: (0, "GOLDEN LINE"),
                                   resolver=_resolver)
        self.assertTrue(harness.check(md, comp("GOLDEN LINE"), r_same)["passed"])

    def test_check_continues_past_failure_multistep(self):
        # Two steps: step one FAILS (output lacks "ok-one"), step two PASSES
        # (output has "ok-two"). Proves check() runs BOTH (results length 2)
        # and does not stop after the first failure — the second still passes.
        md = ("<!-- @verify host=h step=one expect=/ok-one/ -->\n```bash\na\n```\n"
              "<!-- @verify host=h step=two expect=/ok-two/ -->\n```bash\nb\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {}, "normalizers": {},
                "steps": [
                    {"step": "one", "host": "h", "command": "a", "rc": 0,
                     "expect": ["ok-one"], "strict": False, "captured": ""},
                    {"step": "two", "host": "h", "command": "b", "rc": 0,
                     "expect": ["ok-two"], "strict": False, "captured": ""}]}
        r = runner.StepRunner("core", "/root",
                              exec_fn=lambda t, h, script: (0, "ok-two"),
                              resolver=_resolver)
        out = harness.check(md, comp, r)
        self.assertEqual(len(out["results"]), 2)
        self.assertFalse(out["results"][0]["passed"])
        self.assertTrue(out["results"][1]["passed"])
        self.assertFalse(out["passed"])

    def test_run_steps_stop_on_error_halts_remaining_steps(self):
        steps = [{"step": "a", "host": "issueca", "command": "x", "captures": []},
                 {"step": "b", "host": "issueca", "command": "y", "captures": []}]
        def make_runner(calls):
            def exec_fn(t, h, script):
                calls.append(script)
                raise RuntimeError("boom")
            return runner.StepRunner("core", "/root", exec_fn=exec_fn, resolver=_resolver)
        calls1 = []
        recs, _ = harness._run_steps(steps, {}, make_runner(calls1), stop_on_error=True)
        self.assertEqual(len(recs), 1)          # stopped after first failure
        self.assertEqual(calls1, ["x"])          # step b never executed
        self.assertIsNotNone(recs[0]["run_error"])
        calls2 = []
        recs2, _ = harness._run_steps(steps, {}, make_runner(calls2))  # default continues
        self.assertEqual(len(recs2), 2)
        self.assertEqual(calls2, ["x", "y"])

    def test_preamble_is_host_scoped(self):
        # A manage1 PowerShell preamble must NOT be prepended to a `lab` bash step.
        md = ("<!-- @verify host=manage1 step=setup preamble=true -->\n"
              "```powershell\n$Work = 1\n```\n"
              "<!-- @verify host=lab step=hc expect=/up/ -->\n"
              "```bash\ncheck\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {}, "normalizers": {},
                "steps": [
                    {"step": "setup", "host": "manage1", "command": "$Work = 1",
                     "rc": 0, "expect": [], "strict": False, "captured": ""},
                    {"step": "hc", "host": "lab", "command": "check",
                     "rc": 0, "expect": ["up"], "strict": False, "captured": ""}]}
        scripts = {}
        def exec_fn(t, h, script):
            scripts[h] = script
            return (0, "up")
        r = runner.StepRunner("core", "/root", exec_fn=exec_fn, resolver=_resolver)
        harness.check(md, comp, r)
        self.assertIn("$Work = 1", scripts["manage1"])   # preamble applied on its own host
        self.assertNotIn("$Work = 1", scripts["lab"])    # NOT cross-applied to the bash host
        self.assertIn("check", scripts["lab"])

    def test_check_continues_when_a_host_is_unresolvable(self):
        md = ("<!-- @verify host=badvm step=one expect=/x/ -->\n```powershell\na\n```\n"
              "<!-- @verify host=manage1 step=two expect=/ok/ -->\n```powershell\nb\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {}, "normalizers": {},
                "steps": [
                    {"step": "one", "host": "badvm", "command": "a", "rc": 0,
                     "expect": ["x"], "strict": False, "captured": ""},
                    {"step": "two", "host": "manage1", "command": "b", "rc": 0,
                     "expect": ["ok"], "strict": False, "captured": ""}]}
        def resolver(vm, profile, root):
            if vm == "badvm":
                return {"available": False, "reason": "vm not in inventory"}
            return {"available": True, "transport": "winrm", "vm": vm}
        r = runner.StepRunner("core", "/root",
                              exec_fn=lambda t, h, script: (0, "ok"),
                              resolver=resolver)
        out = harness.check(md, comp, r)
        self.assertEqual(len(out["results"]), 2)         # did NOT abort on step one
        self.assertFalse(out["results"][0]["passed"])    # badvm -> FAIL, not crash
        self.assertTrue(any("unresolvable" in x for x in out["results"][0]["reasons"]))
        self.assertTrue(out["results"][1]["passed"])     # step two still ran

    def test_check_threads_capture_into_later_step(self):
        # step 'enroll' output yields RequestId=2a; step 'revoke' consumes
        # $RequestId. The fake exec asserts the value reached revoke's script.
        md = ("<!-- @verify host=issueca step=enroll "
              "capture=RequestId:/RequestID=([0-9A-Fa-f]+)/ expect=/RequestID/ -->\n"
              "```powershell\nissue\n```\n\n"
              "<!-- @verify host=issueca step=revoke expect=/revoked/ -->\n"
              "```powershell\ncertutil -revoke $RequestId\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {}, "normalizers": {},
                "steps": [{"step": "enroll", "host": "issueca", "command": "issue",
                           "rc": 0, "expect": ["RequestID"], "strict": False, "captured": ""},
                          {"step": "revoke", "host": "issueca",
                           "command": "certutil -revoke $RequestId",
                           "rc": 0, "expect": ["revoked"], "strict": False, "captured": ""}]}
        def exec_fn(transport, host, script):
            if "issue" in script:
                return (0, "Re-issued: RequestID=2a SerialNumber=1f00")
            assert "$RequestId = '2a'" in script, script
            return (0, "certificate revoked")
        r = runner.StepRunner("core", "/root", exec_fn=exec_fn, resolver=_resolver)
        out = harness.check(md, comp, r)
        self.assertTrue(out["passed"], out["results"])

    def test_check_capture_no_match_fails_producer_and_consumer(self):
        md = ("<!-- @verify host=issueca step=enroll "
              "capture=RequestId:/RequestID=([0-9A-Fa-f]+)/ -->\n"
              "```powershell\nissue\n```\n\n"
              "<!-- @verify host=issueca step=revoke expect=/revoked/ -->\n"
              "```powershell\ncertutil -revoke $RequestId\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {}, "normalizers": {},
                "steps": [{"step": "enroll", "host": "issueca", "command": "issue",
                           "rc": 0, "expect": [], "strict": False, "captured": ""},
                          {"step": "revoke", "host": "issueca",
                           "command": "certutil -revoke $RequestId",
                           "rc": 0, "expect": ["revoked"], "strict": False, "captured": ""}]}
        # enroll output lacks RequestID -> capture fails; revoke sees empty $RequestId
        r = runner.StepRunner("core", "/root",
                              exec_fn=lambda t, h, s: (0, "nothing useful"),
                              resolver=_resolver)
        out = harness.check(md, comp, r)
        self.assertFalse(out["passed"])
        enroll = next(x for x in out["results"] if x["step"] == "enroll")
        self.assertFalse(enroll["passed"])
        self.assertTrue(any("RequestId" in reason for reason in enroll["reasons"]))

    def test_lint_resolves_var_from_earlier_capture(self):
        md = ("<!-- @verify host=issueca step=enroll "
              "capture=RequestId:/RequestID=([0-9A-Fa-f]+)/ -->\n"
              "```powershell\nissue\n```\n\n"
              "<!-- @verify host=issueca step=revoke -->\n"
              "```powershell\ncertutil -revoke $RequestId\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {},
                "steps": [{"step": "enroll"}, {"step": "revoke"}]}
        r = runner.StepRunner("core", "/root", exec_fn=lambda *a: (0, ""),
                              resolver=_resolver)
        probs = harness.lint(md, comp, r)
        assert not any("RequestId" in p for p in probs), probs

    def test_lint_flags_forward_reference(self):
        md = ("<!-- @verify host=issueca step=revoke -->\n"
              "```powershell\ncertutil -revoke $RequestId\n```\n\n"
              "<!-- @verify host=issueca step=enroll "
              "capture=RequestId:/RequestID=([0-9A-Fa-f]+)/ -->\n"
              "```powershell\nissue\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {},
                "steps": [{"step": "revoke"}, {"step": "enroll"}]}
        r = runner.StepRunner("core", "/root", exec_fn=lambda *a: (0, ""),
                              resolver=_resolver)
        probs = harness.lint(md, comp, r)
        assert any("later step" in p and "RequestId" in p for p in probs), probs

    def test_lint_same_step_self_capture_reference_flagged(self):
        md = ("<!-- @verify host=issueca step=s capture=X:/X=(\\d+)/ -->\n"
              "```powershell\necho $X\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {}, "steps": [{"step": "s"}]}
        r = runner.StepRunner("core", "/root", exec_fn=lambda *a: (0, ""), resolver=_resolver)
        probs = harness.lint(md, comp, r)
        self.assertTrue(any("this or a later step" in p and "X" in p for p in probs), probs)

    def test_lint_warns_capture_shadows_parameter(self):
        md = ("<!-- @verify host=issueca step=enroll "
              "capture=CA:/CA=([A-Za-z]+)/ -->\n```powershell\nissue\n```\n")
        comp = {"lab": "x", "profile": "core", "parameters": {"CA": "X"},
                "steps": [{"step": "enroll"}]}
        r = runner.StepRunner("core", "/root", exec_fn=lambda *a: (0, ""),
                              resolver=_resolver)
        probs = harness.lint(md, comp, r)
        assert any("shadows" in p and "CA" in p for p in probs), probs

import subprocess

class TestCLI(unittest.TestCase):
    def test_lint_subcommand_exit_zero_on_clean(self):
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        # `-m walkverify` needs cwd = the PARENT of the walkverify package
        # (here IS the package dir), so that `walkverify` resolves as a module.
        root = os.path.dirname(here)
        fix = os.path.join(here, "tests", "fixtures")
        p = subprocess.run(
            [sys.executable, "-m", "walkverify", "lint",
             os.path.join(fix, "sample-lab.md"),
             "--companion", os.path.join(fix, "sample-lab.golden.yml")],
            cwd=root, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)

class TestPathMath(unittest.TestCase):
    def _load_main(self):
        import importlib.util
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # walkverify dir
        spec = importlib.util.spec_from_file_location(
            "walkverify_main", os.path.join(here, "__main__.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, here

    def test_default_companion_anchored_on_repo_not_labpath(self):
        mod, here = self._load_main()
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(here)))
        p = mod._default_companion("/somewhere/else/docs/walkthroughs/labs/foo.md")
        self.assertEqual(p, os.path.join(repo_root, "docs", "walkthroughs",
                                         "walkverify", "foo.golden.yml"))
        self.assertNotIn(os.path.join("docs", "docs"), p)  # not doubled

    def test_default_vagrant_root_not_doubled_and_exists(self):
        mod, _ = self._load_main()
        self.assertTrue(mod._DEFAULT_VAGRANT_ROOT.endswith(
            os.path.join("straylight", "vagrant")))
        self.assertNotIn(os.path.join("vagrant", "vagrant"),
                         mod._DEFAULT_VAGRANT_ROOT)
        self.assertTrue(os.path.isdir(mod._DEFAULT_VAGRANT_ROOT))

if __name__ == "__main__":
    unittest.main()
