"""Tests for cbom_diff's stable fingerprint.

Run from cbom-toolkit/python/:
    python3 -m unittest tests.test_cbom_diff -v

A certificate re-issued on a fresh cold build gets new validity timestamps
and a new keypair (so a new subjectPublicKeyRef UUID), but its crypto
IDENTITY — subject, issuer, format, signing algorithm, key type — is
unchanged. The fingerprint must treat those two as the same component so
baseline drift-detection reports only genuine crypto changes, not
per-issuance churn (2026-07-10: baselines diffed on every build purely from
re-issuance).
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cbom_diff  # noqa: E402


def _algo(ref, name):
    return {"bom-ref": ref, "type": "cryptographic-asset", "name": name,
            "cryptoProperties": {"assetType": "algorithm"}}


def _key(ref, name):
    return {"bom-ref": ref, "type": "cryptographic-asset", "name": name,
            "cryptoProperties": {"assetType": "related-crypto-material",
                                 "relatedCryptoMaterialProperties": {"type": "public-key", "size": 256}}}


def _cert(ref, subject, issuer, sig_ref, key_ref, before, after):
    return {"bom-ref": ref, "type": "cryptographic-asset",
            "name": f"{subject} cert",
            "cryptoProperties": {
                "assetType": "certificate",
                "certificateProperties": {
                    "certificateFormat": "X.509",
                    "subjectName": subject,
                    "issuerName": issuer,
                    "signatureAlgorithmRef": sig_ref,
                    "subjectPublicKeyRef": key_ref,
                    "notValidBefore": before,
                    "notValidAfter": after,
                }}}


def _bom(components):
    return {"bomFormat": "CycloneDX", "specVersion": "1.6", "components": components}


class TestStableFingerprint(unittest.TestCase):
    def test_reissued_cert_is_not_a_change(self):
        # Same logical cert, re-issued: new validity times, new keypair ref
        # (pointing to a fresh key component of the SAME name/type), new
        # signature-algo ref UUID (same algo name). Zero changes expected.
        before = _bom([
            _algo("a-old", "ecdsa-with-SHA256"),
            _key("k-old", "id-ecPublicKey"),
            _cert("c-old", "CN=EJBCA-Root-CA", "CN=EJBCA-Root-CA",
                  "a-old", "k-old", "2026-05-20T17:59:00Z", "2036-05-18T17:59:00Z"),
        ])
        after = _bom([
            _algo("a-new", "ecdsa-with-SHA256"),
            _key("k-new", "id-ecPublicKey"),
            _cert("c-new", "CN=EJBCA-Root-CA", "CN=EJBCA-Root-CA",
                  "a-new", "k-new", "2026-07-08T21:20:00Z", "2036-07-06T21:20:00Z"),
        ])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["total_changes"], 0, r["changes"])

    def test_changed_signature_algorithm_is_a_change(self):
        # Same subject/issuer but the cert is now signed with a DIFFERENT
        # algorithm -> genuine drift, must be reported (added + removed).
        before = _bom([
            _algo("a1", "ecdsa-with-SHA256"),
            _cert("c1", "CN=Leaf", "CN=CA", "a1", "k1", "t0", "t1"),
        ])
        after = _bom([
            _algo("a2", "ML-DSA-65"),
            _cert("c2", "CN=Leaf", "CN=CA", "a2", "k1", "t2", "t3"),
        ])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["added_certs"], 1)
        self.assertEqual(r["summary"]["removed_certs"], 1)

    def test_new_subject_cert_is_added(self):
        before = _bom([_algo("a", "rsa"),
                       _cert("c1", "CN=A", "CN=CA", "a", "k", "t0", "t1")])
        after = _bom([_algo("a", "rsa"),
                      _cert("c1", "CN=A", "CN=CA", "a", "k", "t0", "t1"),
                      _cert("c2", "CN=B", "CN=CA", "a", "k", "t0", "t1")])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["added_certs"], 1)
        self.assertEqual(r["summary"]["removed_certs"], 0)

    def test_non_crypto_component_still_identified_by_name(self):
        before = _bom([{"type": "library", "name": "openssl"}])
        after = _bom([{"type": "library", "name": "openssl"}])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["total_changes"], 0)

    def test_unresolvable_ref_does_not_crash_and_stays_stable(self):
        # A *Ref pointing at a component not present resolves to a constant
        # placeholder, so two BOMs with the same dangling ref still match.
        before = _bom([_cert("c1", "CN=A", "CN=CA", "missing", "gone", "t0", "t1")])
        after = _bom([_cert("c2", "CN=A", "CN=CA", "missing", "gone", "t9", "t9")])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["total_changes"], 0)

    def test_rdn_reordering_is_not_a_change(self):
        # A scanner emits the same DN with its RDN components in a different
        # order (Smallstep serializes CN,O one run and O,CN the next). Same
        # logical cert -> zero changes.
        before = _bom([_algo("a", "ecdsa-with-SHA256"), _cert(
            "c1", "CN=A", "commonName=Smallstep Intermediate, organizationName=Smallstep",
            "a", "k", "t0", "t1")])
        after = _bom([_algo("a", "ecdsa-with-SHA256"), _cert(
            "c2", "CN=A", "organizationName=Smallstep, commonName=Smallstep Intermediate",
            "a", "k", "t2", "t3")])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["total_changes"], 0, r["changes"])

    def test_ejbca_container_uid_is_masked(self):
        # The EJBCA/PrimeKey Quickstart container mints a fresh ManagementCA
        # userId ("c-<16+ chars>") on every redeploy, embedded in the CA's DN.
        # Two rebuilds of the same CA differ only in that token -> no change.
        subj = "userId=c-08qf54kaiescyqlvu, commonName=ejbca1.lab, organizationName=PrimeKey"
        subj2 = "userId=c-0r5xo5w040cfffsyw, commonName=ejbca1.lab, organizationName=PrimeKey"
        before = _bom([_algo("a", "sha256WithRSAEncryption"),
                       _cert("c1", subj, subj, "a", "k", "t0", "t1")])
        after = _bom([_algo("a", "sha256WithRSAEncryption"),
                      _cert("c2", subj2, subj2, "a", "k", "t2", "t3")])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["total_changes"], 0, r["changes"])

    def test_genuinely_different_dn_still_differs(self):
        # Canonicalization must not collapse two DNs with different CONTENT.
        before = _bom([_algo("a", "rsa"),
                       _cert("c1", "commonName=Alice, organizationName=Lab", "CN=CA",
                             "a", "k", "t0", "t1")])
        after = _bom([_algo("a", "rsa"),
                      _cert("c2", "commonName=Bob, organizationName=Lab", "CN=CA",
                            "a", "k", "t0", "t1")])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["added_certs"], 1)
        self.assertEqual(r["summary"]["removed_certs"], 1)

    def test_dn_value_containing_comma_is_not_split_mid_value(self):
        # A DN value with an internal comma ("O=Acme, Inc.") must not be torn
        # apart by RDN splitting; identical DNs stay identical.
        dn = "commonName=x, organizationName=Acme, Inc."
        before = _bom([_algo("a", "rsa"), _cert("c1", dn, "CN=CA", "a", "k", "t0", "t1")])
        after = _bom([_algo("a", "rsa"), _cert("c2", dn, "CN=CA", "a", "k", "t9", "t9")])
        r = cbom_diff.diff_from_boms(before, after)
        self.assertEqual(r["summary"]["total_changes"], 0, r["changes"])


if __name__ == "__main__":
    unittest.main()
