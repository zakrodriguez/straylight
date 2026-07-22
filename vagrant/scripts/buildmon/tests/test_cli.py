import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cli  # noqa: E402

class TestCli(unittest.TestCase):
    def test_parser_collect(self):
        p = cli.build_parser()
        ns = p.parse_args(["collect", "--logdir", "logs/x", "--profile", "core", "--no-guest-probe"])
        self.assertEqual(ns.cmd, "collect")
        self.assertEqual(ns.logdir, "logs/x")
        self.assertEqual(ns.profile, "core")
        self.assertTrue(ns.no_guest_probe)

    def test_parser_watch_defaults(self):
        ns = cli.build_parser().parse_args(["watch", "--logdir", "logs/x"])
        self.assertEqual(ns.cmd, "watch")
        self.assertEqual(ns.interval, 2)

    def test_vbox_names_fallback_soft_result_with_profile(self):
        # Attempted regardless of profile; VBoxManage may be absent in CI, so the
        # result is soft — None or a list, same as the no-profile case.
        result = cli._vbox_names_fallback("core")
        self.assertTrue(result is None or isinstance(result, list))

    def test_vbox_names_fallback_soft_fails_without_vboxmanage(self):
        # Must never raise even if VBoxManage is missing/unreachable.
        result = cli._vbox_names_fallback(None)
        self.assertTrue(result is None or isinstance(result, list))


class TestLogdirValidation(unittest.TestCase):
    def test_collect_rejects_non_directory_logdir(self):
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".log") as f:   # a FILE, not a dir
            args = cli.build_parser().parse_args(["collect", "--logdir", f.name])
            self.assertEqual(cli.cmd_collect(args), 2)


class TestList(unittest.TestCase):
    def _fixture(self, root):
        import json, time
        logs = os.path.join(root, "logs"); os.makedirs(logs)
        pdir = os.path.join(root, "profiles"); os.makedirs(pdir)
        with open(os.path.join(pdir, "core.yml"), "w") as fh:
            fh.write("components:\n  - dc1\n  - web1\n")
        with open(os.path.join(pdir, "ejbca-only.yml"), "w") as fh:
            fh.write("components:\n  - ejbca1\n  - scanner1\n")
        # validate-only dir → not a build, skipped
        v = os.path.join(logs, "20260702-000001"); os.makedirs(v)
        open(os.path.join(v, "validate.log"), "w").close()
        # core build with a live feed
        b1 = os.path.join(logs, "20260702-000002"); os.makedirs(b1)
        for f in ("dc1-create.log", "web1-create.log"):
            open(os.path.join(b1, f), "w").close()
        os.makedirs(os.path.join(b1, "buildmon"))
        now = 1782950000.0
        updated = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 5))
        with open(os.path.join(b1, "buildmon", "status.json"), "w") as fh:
            json.dump({"build": {"phase": "creating", "updated_at": updated}}, fh)
        # ejbca build, newer, no feed yet
        b2 = os.path.join(logs, "20260702-000003"); os.makedirs(b2)
        open(os.path.join(b2, "ejbca1-create.log"), "w").close()
        return logs, pdir, now

    def test_list_rows_newest_first_skips_non_builds(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            logs, pdir, now = self._fixture(root)
            rows = cli._list_rows(logs, 10, None, None, now, profiles_dir=pdir)
            self.assertEqual([os.path.basename(r[0]) for r in rows],
                             ["20260702-000003", "20260702-000002"])
            d, profile, phase, feed, age, max_attempt = rows[1]
            self.assertEqual((profile, phase, feed, age), ("core", "creating", "live", 5))
            self.assertEqual(max_attempt, 1)   # no attempt data in the feed → default
            self.assertEqual(rows[0][3], "none")   # newer build has no feed yet

    def test_list_rows_profile_filter_selects_matching_build(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            logs, pdir, now = self._fixture(root)
            rows = cli._list_rows(logs, 10, "core", None, now, profiles_dir=pdir)
            # the newer ejbca build must NOT win — its VMs don't fit 'core'
            self.assertEqual([os.path.basename(r[0]) for r in rows], ["20260702-000002"])
            self.assertEqual(rows[0][1], "core")


class TestResetAttempts(unittest.TestCase):
    def test_writes_marker_with_explicit_profile_and_stamp(self):
        import tempfile, os
        import cli, history
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "20260702-120000"))
            rc = cli.main(["reset-attempts", "--logs-root", root,
                           "--profile", "pqc-full", "--stamp", "20260702-120000"])
            self.assertEqual(rc, 0)
            self.assertEqual(history.read_reset_cutoff(root, "pqc-full"),
                             "20260702-120000")

    def test_defaults_stamp_to_newest_logdir(self):
        import tempfile, os
        import cli, history
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "20260702-100000"))
            os.makedirs(os.path.join(root, "20260702-130000"))
            rc = cli.main(["reset-attempts", "--logs-root", root, "--profile", "pqc-full"])
            self.assertEqual(rc, 0)
            self.assertEqual(history.read_reset_cutoff(root, "pqc-full"),
                             "20260702-130000")

    def test_unresolvable_profile_errors(self):
        import tempfile
        import cli
        with tempfile.TemporaryDirectory() as root:
            rc = cli.main(["reset-attempts", "--logs-root", root])
            self.assertEqual(rc, 2)

    def test_resolved_profile_but_no_logdir_errors(self):
        import tempfile
        import cli
        with tempfile.TemporaryDirectory() as root:   # empty: no LOGDIR_RE dirs
            rc = cli.main(["reset-attempts", "--logs-root", root, "--profile", "pqc-full"])
            self.assertEqual(rc, 2)


class TestListReprovisionMarker(unittest.TestCase):
    def test_list_flags_reprovision(self):
        import tempfile, os, io, contextlib
        import cli
        with tempfile.TemporaryDirectory() as root:
            logdir = os.path.join(root, "20260702-120000")
            d = os.path.join(logdir, "buildmon")
            os.makedirs(d)
            # a VM log is required for logdir_vm_stems() to recognize this as a
            # build dir at all (matches the convention used by TestList._fixture)
            open(os.path.join(logdir, "manage1-create.log"), "w").close()
            with open(os.path.join(d, "status.json"), "w") as fh:
                fh.write(
                    '{"schema":"buildmon/v1","build":{"profile":"pqc-full",'
                    '"phase":"parallel-provision","counts":{"total":1,"done":0},'
                    '"updated_at":"2026-07-02T18:00:00Z"},'
                    '"vms":{"manage1":{"state":"provisioning","attempt":3,'
                    '"prior":{"failed":1,"interrupted":1}}}}')
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["list", "--logs-root", root, "--porcelain"])
            self.assertIn("reprovision(3)", buf.getvalue())

    def test_list_human_mode_appends_reprovision_marker(self):
        import tempfile, os, io, contextlib
        import cli
        with tempfile.TemporaryDirectory() as root:
            logdir = os.path.join(root, "20260702-120000")
            d = os.path.join(logdir, "buildmon")
            os.makedirs(d)
            # a VM log is required for logdir_vm_stems() to recognize this as a
            # build dir at all (matches the convention used by TestList._fixture)
            open(os.path.join(logdir, "manage1-create.log"), "w").close()
            with open(os.path.join(d, "status.json"), "w") as fh:
                fh.write(
                    '{"schema":"buildmon/v1","build":{"profile":"pqc-full",'
                    '"phase":"parallel-provision","counts":{"total":1,"done":0},'
                    '"updated_at":"2026-07-02T18:00:00Z"},'
                    '"vms":{"manage1":{"state":"provisioning","attempt":3,'
                    '"prior":{"failed":1,"interrupted":1}}}}')
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["list", "--logs-root", root])
            self.assertIn("reprovision(3)", buf.getvalue())

    def test_list_human_mode_no_marker_when_no_reprovision(self):
        import tempfile, os, io, contextlib
        import cli
        with tempfile.TemporaryDirectory() as root:
            logdir = os.path.join(root, "20260702-120000")
            d = os.path.join(logdir, "buildmon")
            os.makedirs(d)
            open(os.path.join(logdir, "manage1-create.log"), "w").close()
            with open(os.path.join(d, "status.json"), "w") as fh:
                fh.write(
                    '{"schema":"buildmon/v1","build":{"profile":"pqc-full",'
                    '"phase":"parallel-provision","counts":{"total":1,"done":0},'
                    '"updated_at":"2026-07-02T18:00:00Z"},'
                    '"vms":{"manage1":{"state":"provisioning"}}}')
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                cli.main(["list", "--logs-root", root])
            self.assertNotIn("reprovision", buf.getvalue())


class TestOnEventFlag(unittest.TestCase):
    def test_collect_parser_accepts_on_event(self):
        import cli
        args = cli.build_parser().parse_args(
            ["collect", "--logdir", "/tmp/x", "--on-event", "notify-send hi"])
        self.assertEqual(args.on_event, "notify-send hi")

    def test_on_event_default_none(self):
        import cli
        args = cli.build_parser().parse_args(["collect", "--logdir", "/tmp/x"])
        self.assertIsNone(args.on_event)


if __name__ == "__main__":
    unittest.main()
