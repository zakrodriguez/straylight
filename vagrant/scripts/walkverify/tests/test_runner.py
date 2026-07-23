import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import runner  # noqa: E402

def _step(**kw):
    base = {"step": "s", "host": "manage1", "command": "certutil -config $CA -ping",
            "expects": [], "rc": 0, "strict": False, "preamble": False}
    base.update(kw)
    return base

def _ok_resolver(vm, profile, root):
    return {"available": True, "transport": "winrm", "vm": vm}

class TestRunner(unittest.TestCase):
    def test_assemble_threads_params_and_preamble(self):
        r = runner.StepRunner("pqc-full", "/root", resolver=_ok_resolver)
        script = r.assemble(_step(), {"CA": "X\\Y"}, "$Work = 'C:\\\\w'")
        self.assertIn("$CA = 'X\\Y'", script)
        self.assertIn("$Work = 'C:\\\\w'", script)
        self.assertTrue(script.strip().endswith("certutil -config $CA -ping"))

    def test_preamble_step_does_not_prepend_itself(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(step="setup", command="$Work = 'C:\\\\w'", preamble=True)
        script = r.assemble(s, {}, "$Work = 'C:\\\\w'")
        self.assertEqual(script.count("$Work = 'C:\\\\w'"), 1)

    def test_unresolved_reports_missing_var(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        self.assertEqual(r.unresolved(_step(), {}, ""), ["CA"])
        self.assertEqual(r.unresolved(_step(), {"CA": "z"}, ""), [])

    def test_unresolved_satisfied_by_preamble(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(command="use $Work")
        self.assertEqual(r.unresolved(s, {}, "$Work = 'x'"), [])

    def test_run_uses_injected_exec(self):
        calls = {}
        def fake_exec(transport, host, script):
            calls.update(transport=transport, host=host, script=script)
            return (0, "interface is alive")
        r = runner.StepRunner("p", "/root", exec_fn=fake_exec, resolver=_ok_resolver)
        out = r.run(_step(), {"CA": "z"}, "")
        self.assertEqual(out, {"stdout": "interface is alive", "rc": 0})
        self.assertEqual(calls["transport"], "winrm")
        self.assertEqual(calls["host"], "manage1")

    def test_run_raises_when_host_unresolvable(self):
        def bad_resolver(vm, profile, root):
            return {"available": False, "reason": "vm not in inventory"}
        r = runner.StepRunner("p", "/root", exec_fn=lambda *a: (0, ""),
                              resolver=bad_resolver)
        with self.assertRaises(runner.RunnerError):
            r.run(_step(), {"CA": "z"}, "")

    def test_preamble_reference_without_assignment_still_flags(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(command="use $CA")
        # preamble merely LOGS $CA, never assigns it -> CA still unresolved
        self.assertEqual(r.unresolved(s, {}, "Write-Host $CA"), ["CA"])

    def test_preamble_step_flags_its_own_undefined_reference(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(step="setup", command="$Work = $BaseDir", preamble=True)
        # $Work is assigned (defined); $BaseDir is referenced but never supplied
        self.assertEqual(r.unresolved(s, {}, ""), ["BaseDir"])

    def test_assign_single_quotes_and_escapes(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        script = r.assemble(_step(command="echo done"), {"P": "a'b$env:X"}, "")
        self.assertIn("$P = 'a''b$env:X'", script)

    def test_local_host_uses_local_transport_no_injection(self):
        seen = {}
        def fake_exec(transport, host, script):
            seen.update(transport=transport, host=host, script=script)
            return (0, "up")
        r = runner.StepRunner("core", "/root", exec_fn=fake_exec, resolver=_ok_resolver)
        s = _step(host="lab", command="nc -zv 1.2.3.4 135")
        out = r.run(s, {"CA": "X"}, "$Work = 1")   # params/preamble must NOT leak in
        self.assertEqual(seen["transport"], "local")
        self.assertEqual(seen["script"], "nc -zv 1.2.3.4 135")
        self.assertNotIn("$CA", seen["script"])
        self.assertNotIn("$Work", seen["script"])
        self.assertEqual(out, {"stdout": "up", "rc": 0})

    def test_local_default_exec_runs_bash_and_combines_channels(self):
        r = runner.StepRunner("core", "/tmp", resolver=_ok_resolver)
        out = r.run(_step(host="lab", command="echo out; echo err 1>&2"), {}, "")
        self.assertEqual(out["rc"], 0)
        self.assertIn("out", out["stdout"])
        self.assertIn("err", out["stdout"])   # stderr combined into stdout

    def test_assemble_injects_bindings(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(command="certutil -config $CA -revoke $SerialNumber")
        script = r.assemble(s, {"CA": "X\\Y"}, "", {"SerialNumber": "1f00"})
        assert "$SerialNumber = '1f00'" in script
        assert "$CA = 'X\\Y'" in script

    def test_binding_wins_on_collision_with_parameter(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(command="echo $V")
        script = r.assemble(s, {"V": "static"}, "", {"V": "runtime"})
        assert "$V = 'runtime'" in script
        assert "$V = 'static'" not in script

    def test_local_host_gets_no_binding_injection(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(host=runner.LOCAL_HOST, command="echo hi")
        assert r.assemble(s, {"CA": "X"}, "", {"S": "1"}) == "echo hi"

    def test_unresolved_satisfied_by_captured_name(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(command="certutil -revoke $SerialNumber")
        assert r.unresolved(s, {}, "", {"SerialNumber"}) == []
        assert r.unresolved(s, {}, "", set()) == ["SerialNumber"]

    def test_unresolved_ignores_within_step_assignment_and_automatic_vars(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(command="$ids = certutil -view | ForEach-Object { $_ }\nWrite-Output $ids")
        assert r.unresolved(s, {}, "", set()) == []  # $ids assigned in-step; $_ automatic

    def test_unresolved_still_flags_truly_undefined_multiline(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        s = _step(command="$x = 1\ncertutil -config $CA -ping")
        assert r.unresolved(s, {}, "", set()) == ["CA"]  # $x assigned; $CA still flagged

    def test_unresolved_credits_bash_assignment_on_lab_host_only(self):
        r = runner.StepRunner("p", "/root", resolver=_ok_resolver)
        cmd = "RG=rg-straylight-az700-hub-spoke\naz group show --name $RG"
        assert r.unresolved(_step(host="lab", command=cmd), {}, "", set()) == []
        # command-substitution assignments count too
        sub = "IP=$(az network public-ip show --query ipAddress -o tsv)\necho $IP"
        assert r.unresolved(_step(host="lab", command=sub), {}, "", set()) == []
        # on a PowerShell host the same text is NOT an assignment — still flagged
        assert r.unresolved(_step(host="manage1", command=cmd), {}, "", set()) == ["RG"]

if __name__ == "__main__":
    unittest.main()
