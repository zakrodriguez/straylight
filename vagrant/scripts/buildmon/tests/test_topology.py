import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import topology  # noqa: E402

class TestTopology(unittest.TestCase):
    def test_from_profile_yaml_dc1_first(self):
        with tempfile.TemporaryDirectory() as d:
            pdir = os.path.join(d, "profiles"); os.makedirs(pdir)
            with open(os.path.join(pdir, "core.yml"), "w") as fh:
                fh.write("components:\n  - web1\n  - ca1\n  - dc1\n  - manage1\n")
            res = topology.resolve("core", logdir=d, profiles_dir=pdir)
            names = [r[0] for r in res]
            self.assertEqual(names[0], "dc1")                 # dc1 forced first
            self.assertEqual(set(names), {"dc1", "ca1", "web1", "manage1"})
            roles = dict((r[0], r[1]) for r in res)
            self.assertEqual(roles["dc1"], "domain_controller")

    def test_from_logdir_when_no_profile(self):
        with tempfile.TemporaryDirectory() as d:
            for f in ("dc1.log", "ca1.log", "ca1-create.log", "web1.log"):
                open(os.path.join(d, f), "w").close()
            res = topology.resolve(None, logdir=d)
            self.assertEqual(set(r[0] for r in res), {"dc1", "ca1", "web1"})  # no duplicate ca1

    def test_logdir_stems_create_logs_counted_non_vm_excluded(self):
        with tempfile.TemporaryDirectory() as d:
            for f in ("dc1.log", "dc1-create.log", "web1-create.log", "ansible.log",
                      "validate.log", "ca1-snap.log", "ca1-rebuild.log"):
                open(os.path.join(d, f), "w").close()
            self.assertEqual(topology.logdir_vm_stems(d), ["dc1", "web1"])

    def test_resolve_from_create_logs_only(self):
        # Phase 1: create logs exist for every VM but no provision log yet — the
        # full VM set must resolve here instead of falling to the VBox tier,
        # which mixes machines from every registered lab when several run at once.
        with tempfile.TemporaryDirectory() as d:
            for f in ("web1-create.log", "dc1-create.log"):
                open(os.path.join(d, f), "w").close()
            names = [r[0] for r in topology.resolve(None, logdir=d)]
            self.assertEqual(names, ["dc1", "web1"])

    def test_vbox_name_map(self):
        self.assertEqual(topology.vbox_name_map("core", ["dc1"]), {"dc1": "straylight-core-dc1"})

    def test_profile_yaml_inline_comments(self):
        with tempfile.TemporaryDirectory() as d:
            pdir = os.path.join(d, "profiles"); os.makedirs(pdir)
            with open(os.path.join(pdir, "lab.yml"), "w") as fh:
                fh.write("components:\n  - dc1\n  - web1   # CRL/AIA distribution\n")
            names = [r[0] for r in topology.resolve("lab", logdir=d, profiles_dir=pdir)]
            self.assertEqual(names, ["dc1", "web1"])   # web1 must survive the comment

    def test_vbox_names_dash_profile_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            pdir = os.path.join(d, "profiles"); os.makedirs(pdir)
            open(os.path.join(pdir, "sql-cert-labs.yml"), "w").close()
            res = topology.resolve(None, logdir=os.path.join(d, "nope"),
                                   vbox_names=["straylight-sql-cert-labs-web1"], profiles_dir=pdir)
            self.assertEqual(res, [("web1", "web_server", 0)])


class TestInferProfile(unittest.TestCase):
    def _mkprofiles(self, d, profiles):
        pdir = os.path.join(d, "profiles"); os.makedirs(pdir)
        for name, comps in profiles.items():
            with open(os.path.join(pdir, f"{name}.yml"), "w") as fh:
                fh.write("components:\n" + "".join(f"  - {c}\n" for c in comps))
        return pdir

    def _mklogs(self, d, stems):
        logdir = os.path.join(d, "logs"); os.makedirs(logdir)
        for s in stems:
            open(os.path.join(logdir, f"{s}-create.log"), "w").close()
        return logdir

    def test_exact_component_set_match_after_creates_settle(self):
        # An exact match with a superset profile still possible only wins once
        # the create phase has settled (newest create-log older than
        # CREATE_SETTLE_S) — mid-Phase-1, a partially-created "big" build
        # exactly impersonates "two-tier" (#210).
        import time
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"two-tier": ["dc1", "rootca", "issueca"],
                                        "big": ["dc1", "rootca", "issueca", "web1"]})
            logdir = self._mklogs(d, ["dc1", "rootca", "issueca"])
            settled = time.time() + topology.CREATE_SETTLE_S + 60
            self.assertEqual(topology.infer_profile(logdir, pdir, now_epoch=settled),
                             "two-tier")

    def test_exact_match_fresh_superset_pending_is_ambiguous(self):
        # Same stems observed seconds after the last create-log: "big" may
        # still be mid-creation — confidently returning "two-tier" here is the
        # #210 misbind. No clock at all (now_epoch=None) is equally ambiguous.
        import time
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"two-tier": ["dc1", "rootca", "issueca"],
                                        "big": ["dc1", "rootca", "issueca", "web1"]})
            logdir = self._mklogs(d, ["dc1", "rootca", "issueca"])
            self.assertIsNone(topology.infer_profile(logdir, pdir, now_epoch=time.time()))
            self.assertIsNone(topology.infer_profile(logdir, pdir))

    def test_exact_match_no_superset_wins_regardless_of_clock(self):
        import time
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"small": ["dc1"],
                                        "big": ["dc1", "web1"]})
            logdir = self._mklogs(d, ["dc1", "web1"])
            self.assertEqual(topology.infer_profile(logdir, pdir, now_epoch=time.time()),
                             "big")
            self.assertEqual(topology.infer_profile(logdir, pdir), "big")

    def test_exact_vs_superset_vbox_tiebreak(self):
        # While a superset candidate exists and creates are FRESH, single
        # coverage is NOT trusted (#217: a standing two-tier lab covers the
        # early stems while a building "big" lab hasn't registered its own
        # VMs yet). Once creates settle, coverage resolves it.
        import time
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"two-tier": ["dc1", "rootca"],
                                        "big": ["dc1", "rootca", "web1"]})
            logdir = self._mklogs(d, ["dc1", "rootca"])
            only_twotier = ["straylight-two-tier-dc1", "straylight-two-tier-rootca"]
            self.assertIsNone(
                topology.infer_profile(logdir, pdir, vbox_names=only_twotier,
                                       now_epoch=time.time()))
            settled = time.time() + topology.CREATE_SETTLE_S + 60
            self.assertEqual(
                topology.infer_profile(logdir, pdir, vbox_names=only_twotier,
                                       now_epoch=settled),
                "two-tier")
            # After settle the exact match wins BEFORE the tie-break — VBox
            # registration no longer matters (a building "big" would have
            # kept creating; settled stems == two-tier's exact set).
            both = only_twotier + ["straylight-big-dc1", "straylight-big-rootca",
                                   "straylight-big-web1"]
            self.assertEqual(
                topology.infer_profile(logdir, pdir, vbox_names=both,
                                       now_epoch=settled),
                "two-tier")
            # Pre-settle with both registered: ambiguous.
            self.assertIsNone(
                topology.infer_profile(logdir, pdir, vbox_names=both,
                                       now_epoch=time.time()))

    def test_217_standing_superset_lab_does_not_win_fresh_tiebreak(self):
        # Exact #217 repro: three early stems fit MANY supersets and no exact;
        # only the standing two-tier lab covers them in VBox (the building
        # pqc lab hasn't registered manage1/web1 yet). Fresh → None. After
        # settle, coverage may speak.
        import time
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {
                "two-tier": ["dc1", "manage1", "web1", "rootca", "issueca"],
                "pqc": ["dc1", "manage1", "web1", "rootca", "issueca", "scanner1"],
                "one-tier": ["dc1", "manage1", "web1", "ca1"]})
            logdir = self._mklogs(d, ["dc1", "manage1", "web1"])
            standing = ["straylight-two-tier-dc1", "straylight-two-tier-manage1",
                        "straylight-two-tier-web1", "straylight-two-tier-rootca",
                        "straylight-two-tier-issueca"]
            self.assertIsNone(
                topology.infer_profile(logdir, pdir, vbox_names=standing,
                                       now_epoch=time.time()))
            settled = time.time() + topology.CREATE_SETTLE_S + 60
            self.assertEqual(
                topology.infer_profile(logdir, pdir, vbox_names=standing,
                                       now_epoch=settled),
                "two-tier")

    def test_equal_set_tie_no_superset_still_immediate(self):
        # core vs one-tier equal sets with NO superset profile: stems cannot
        # be a partial build of anything known — tie-break stays immediate.
        import time
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"core": ["dc1", "ca1"],
                                        "one-tier": ["ca1", "dc1"]})
            logdir = self._mklogs(d, ["dc1", "ca1"])
            registered = ["straylight-one-tier-dc1", "straylight-one-tier-ca1"]
            self.assertEqual(
                topology.infer_profile(logdir, pdir, vbox_names=registered,
                                       now_epoch=time.time()),
                "one-tier")

    def test_unique_superset_mid_build(self):
        # only rootca-pqc has a log yet; exactly one profile contains it
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"small": ["dc1", "web1"],
                                        "pqc": ["dc1", "web1", "rootca-pqc"]})
            logdir = self._mklogs(d, ["rootca-pqc"])
            self.assertEqual(topology.infer_profile(logdir, pdir), "pqc")

    def test_multiple_supersets_stay_ambiguous(self):
        # dc1 alone fits many profiles — guessing would plant phantom VMs
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"small": ["dc1", "web1"],
                                        "large": ["dc1", "web1", "ejbca1"]})
            logdir = self._mklogs(d, ["dc1"])
            self.assertIsNone(topology.infer_profile(logdir, pdir))

    def test_equal_sets_ambiguous_without_vbox(self):
        # core and ad-cs-one-tier have identical component SETS in the real repo
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"core": ["dc1", "ca1"],
                                        "one-tier": ["ca1", "dc1"]})
            logdir = self._mklogs(d, ["dc1", "ca1"])
            self.assertIsNone(topology.infer_profile(logdir, pdir))

    def test_equal_sets_disambiguated_by_registered_vbox_machines(self):
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"core": ["dc1", "ca1"],
                                        "one-tier": ["ca1", "dc1"]})
            logdir = self._mklogs(d, ["dc1", "ca1"])
            registered = ["straylight-one-tier-dc1", "straylight-one-tier-ca1",
                          "straylight-pqc-full-dc1"]
            self.assertEqual(topology.infer_profile(logdir, pdir, vbox_names=registered),
                             "one-tier")

    def test_no_fit_or_empty_logdir_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            pdir = self._mkprofiles(d, {"core": ["dc1"]})
            self.assertIsNone(topology.infer_profile(self._mklogs(d, []), pdir))
            logdir2 = os.path.join(d, "logs2"); os.makedirs(logdir2)
            open(os.path.join(logdir2, "mystery1-create.log"), "w").close()
            self.assertIsNone(topology.infer_profile(logdir2, pdir))


if __name__ == "__main__":
    unittest.main()
