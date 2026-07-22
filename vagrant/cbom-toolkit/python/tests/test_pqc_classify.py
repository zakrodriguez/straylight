"""Tests for pqc_classify — the single source of truth for PQC classification.

Run from cbom-toolkit/python/ directory:

    python3 -m unittest tests.test_pqc_classify -v

Also runnable directly:

    python3 tests/test_pqc_classify.py

These cases cover the bugs we hit in production over April-May 2026 — keep
them green so they don't come back.
"""
import os
import sys
import unittest

# Make the parent (cbom-toolkit/python/) importable when running directly.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pqc_classify import classify  # noqa: E402


class TestQuantumSafePQC(unittest.TestCase):
    """PQC asymmetric primitives — must classify as quantum-safe."""

    def test_dashed_ml_dsa_variants(self):
        for name in ('ML-DSA-44', 'ML-DSA-65', 'ML-DSA-87'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_undashed_oid_names(self):
        # OID display names use the no-dash form (id-mldsa65, id-mlkem768).
        # Bug: pre-fix these matched the DSA substring in QUANTUM_VULNERABLE
        # first and classified as quantum-vulnerable.
        for name in ('id-mldsa44', 'id-mldsa65', 'id-mldsa87',
                     'id-mlkem512', 'id-mlkem768', 'id-mlkem1024',
                     'id-slhdsa-sha2-128s'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_ml_kem(self):
        for name in ('ML-KEM-512', 'ML-KEM-768', 'ML-KEM-1024',
                     'MLKEM768'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_hybrid_kex_groups(self):
        # OpenSSL 3.5 / IETF naming for hybrid PQC key exchange groups —
        # presence of MLKEM substring wins over the X25519/SecP256r1 prefix.
        for name in ('X25519MLKEM768', 'SecP256r1MLKEM768',
                     'X448MLKEM1024'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_other_pqc_families(self):
        for name in ('SLH-DSA-SHA2-128s', 'XMSS-SHA2_10_256', 'LMS-SHA256-M32-H10'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_kyber_aliases(self):
        # Kyber = ML-KEM (pre-NIST name). GnuPG names the composite
        # `ky768_bp256`. Classifier must recognize both spellings.
        for name in ('Kyber', 'kyber-768', 'kyber512', 'kyber1024',
                     'ky768_bp256', 'ky1024_bp384'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_ssh_pqc_kex(self):
        # OpenSSH 10.0+ default (NIST-standardized) and OpenSSH 9.0+
        # pre-standard PQC KEX. Both quantum-safe; latter must not
        # classify as unknown.
        for name in ('mlkem768x25519-sha256',
                     'sntrup761x25519-sha512@openssh.com',
                     'sntrup761x25519-sha512'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')


class TestQuantumVulnerable(unittest.TestCase):
    """Classical asymmetric primitives — must classify as quantum-vulnerable."""

    def test_rsa_variants_case_insensitive(self):
        # Bug: pre-fix the case-sensitive substring match missed `rsa-2048`,
        # `rsassaPss`, `sha256WithRSAEncryption` because RSA wasn't in upper.
        for name in ('RSA', 'rsa-2048', 'rsa-4096',
                     'rsaEncryption', 'rsassaPss',
                     'sha256WithRSAEncryption', 'sha384WithRSAEncryption'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-vulnerable')

    def test_ecdsa_variants_case_insensitive(self):
        for name in ('ECDSA', 'ecdsa-with-SHA256', 'ecdsa-with-SHA384',
                     'ecdsa-with-SHA512'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-vulnerable')

    def test_ec_oid_names(self):
        # Bug: id-ecPublicKey was the last source of "unknown" in live data.
        for name in ('id-ecPublicKey', 'ID-EC', 'ecPublicKey'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-vulnerable')

    def test_ec_named_curves(self):
        for name in ('prime256v1', 'secp384r1', 'secp521r1', 'secp256k1',
                     'P-256', 'P-384', 'P-521', 'ec-256', 'EC-384'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-vulnerable')

    def test_classical_kex(self):
        for name in ('DH', 'ECDH', 'X25519', 'X448', 'Ed25519', 'Ed448'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-vulnerable')

    def test_ssh_classical_kex(self):
        # SSH names Curve25519/448 as `curve25519-...` (not X25519). Same
        # underlying primitive, still quantum-vulnerable.
        for name in ('curve25519-sha256', 'curve448-sha512'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-vulnerable')


class TestCipherSuiteFalsePositives(unittest.TestCase):
    """The bug-#14 case: TLS cipher suite names mix symmetric + asymmetric.

    Symmetric primitives (AES, SHA-256) appear in PQC_SAFE because they're
    quantum-safe for confidentiality alone, but a cipher suite *containing*
    them isn't safe overall if it also uses RSA/DHE/ECDHE for key exchange
    or signing. Order of operations: classical asymmetric MUST win.
    """

    def test_dhe_rsa_aes_suite_is_vulnerable(self):
        self.assertEqual(
            classify('TLS_DHE_RSA_WITH_AES_128_GCM_SHA256'),
            'quantum-vulnerable',
        )

    def test_ecdhe_ecdsa_aes_suite_is_vulnerable(self):
        self.assertEqual(
            classify('TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384'),
            'quantum-vulnerable',
        )

    def test_pure_pqc_suite_stays_safe(self):
        # Hypothetical hybrid cipher suite where the asymmetric side is PQC.
        self.assertEqual(
            classify('TLS_X25519MLKEM768_WITH_AES_128_GCM_SHA256'),
            'quantum-safe',
        )


class TestSymmetricSafe(unittest.TestCase):
    """Pure symmetric primitives — quantum-safe for confidentiality alone."""

    def test_aes_alone(self):
        for name in ('AES', 'AES-128', 'AES-256', 'AES-GCM'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_sha2_family(self):
        for name in ('SHA-256', 'SHA-384', 'SHA-512', 'SHA3'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')


class TestWeakClassical(unittest.TestCase):
    """Already-broken primitives — flag distinctly."""

    def test_weak_hashes(self):
        for name in ('MD5', 'SHA1', 'SHA-1'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'weak-classical')

    def test_weak_ciphers(self):
        for name in ('DES', '3DES', 'RC4', 'RC2'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'weak-classical')

    def test_md5_with_rsa_is_weak_not_vulnerable(self):
        # Weak-classical wins over quantum-vulnerable when both apply —
        # the security impact (already broken) is more urgent than
        # quantum-vulnerable (broken in N years).
        self.assertEqual(classify('md5WithRSAEncryption'), 'weak-classical')


class TestPreNistPQCNames(unittest.TestCase):
    """Pre-NIST PQC names (CRYSTALS-Dilithium, Falcon) still emitted by
    many tools that haven't caught up to the August 2024 FIPS rename."""

    def test_dilithium_variants(self):
        # Dilithium = ML-DSA (pre-NIST). Must classify as quantum-safe.
        # Bug: bare 'DSA' substring in QUANTUM_VULNERABLE would mis-fire
        # first if Dilithium wasn't checked in the PQC pass.
        for name in ('Dilithium2', 'Dilithium3', 'Dilithium5',
                     'dilithium3', 'CRYSTALS-Dilithium3'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_falcon_variants(self):
        # Falcon = FN-DSA (draft). NIST PQC signature finalist.
        for name in ('Falcon-512', 'Falcon-1024', 'falcon-512', 'FALCON'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')


class TestClassicalOIDs(unittest.TestCase):
    """Bare OID strings emitted by raw cert parsers — must classify."""

    def test_ed25519_oid(self):
        # Ed25519 is classical — not PQC-safe despite the modern name.
        self.assertEqual(classify('1.3.101.112'), 'quantum-vulnerable')

    def test_ed448_oid(self):
        self.assertEqual(classify('1.3.101.113'), 'quantum-vulnerable')

    def test_rsa_oid(self):
        self.assertEqual(classify('1.2.840.113549.1.1.1'), 'quantum-vulnerable')

    def test_ec_publickey_oid(self):
        self.assertEqual(classify('1.2.840.10045.2.1'), 'quantum-vulnerable')


class TestSymmetricNoDashAndChaCha(unittest.TestCase):
    """OpenSSL EVP_MD names use no-dash forms (`sha256` not `SHA-256`);
    ChaCha20-Poly1305 is the TLS 1.3 / OpenSSH AEAD."""

    def test_sha2_no_dash(self):
        for name in ('SHA256', 'SHA384', 'SHA512', 'sha256'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')

    def test_chacha20_poly1305(self):
        for name in ('CHACHA20-POLY1305', 'ChaCha20-Poly1305', 'CHACHA20'):
            with self.subTest(name=name):
                self.assertEqual(classify(name), 'quantum-safe')


class TestCipherSuiteFalsePositivesRegression(unittest.TestCase):
    """Critical regression guard — the bug-#14 cipher-suite tests STILL
    pass after expanding SYMMETRIC_SAFE (adding `SHA256` no-dash) and
    PQC_ASYMMETRIC (adding `DILITHIUM`). Order: VULN(RSA) > SYM(SHA256)."""

    def test_dhe_rsa_aes_sha256_still_vulnerable_no_dash(self):
        # `SHA256` (no-dash) is now in SYMMETRIC_SAFE — order must still
        # let RSA win, otherwise cipher suites with no-dash SHA256 would
        # mis-classify as safe.
        self.assertEqual(
            classify('TLS_DHE_RSA_WITH_AES_128_GCM_SHA256'),
            'quantum-vulnerable',
        )


class TestEdgeCases(unittest.TestCase):
    def test_empty_string(self):
        self.assertEqual(classify(''), 'unknown')

    def test_none_input_is_safe(self):
        # Defensive: no-name components shouldn't crash the pipeline.
        self.assertEqual(classify(None), 'unknown')

    def test_unrecognized_name(self):
        self.assertEqual(classify('CompletelyMadeUpAlgo'), 'unknown')


if __name__ == '__main__':
    unittest.main(verbosity=2)
