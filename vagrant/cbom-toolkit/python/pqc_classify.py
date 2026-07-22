"""Shared PQC classification — single source of truth for cbom_score.py and
cbom_ingest.py.

Bug history:
  - Pre-fix, both modules carried their own copies and drifted apart.
    cbom_score.py was fixed for case-insensitivity + cipher-suite false
    positives (bug #14 in pqc-remediation-progress) but cbom_ingest.py was
    missed, so OpenSearch saw a lot of "unknown" status on certs that the
    scorecard correctly classified.
  - Now both import from here. If you change a constant or rule, both
    consumers pick it up automatically — no more drift.

Classification order matters and is intentional:
  1. WEAK    — classical primitives that are already broken (MD5, SHA-1, DES)
  2. PQC     — definitive: ML-KEM/ML-DSA/SLH-DSA presence wins (must beat
               substring matches on DSA/X25519 etc.)
  3. VULN    — any classical asymmetric primitive marks vulnerable, even if
               the name also contains AES/SHA-256 (TLS cipher-suite case)
  4. BARE EC — word-boundary `EC` after the substring sweep
  5. SYM     — pure symmetric primitives are quantum-safe for confidentiality
"""
import re

PQC_ASYMMETRIC = (
    # Both dashed (ML-DSA) and undashed (MLDSA) forms — OID names like
    # id-mldsa65 / id-mlkem768 use the undashed form. Without MLDSA here,
    # `id-mldsa65` would fall through to the DSA substring match below
    # and classify as quantum-vulnerable.
    'ML-KEM', 'MLKEM', 'ML-DSA', 'MLDSA',
    'SLH-DSA', 'SLHDSA', 'XMSS', 'LMS',
    # Kyber is the pre-NIST name for ML-KEM. NIST renamed it to ML-KEM
    # during standardization (FIPS 203, August 2024) but GnuPG, OpenPGP
    # implementations, and many crypto libraries still use the Kyber
    # name. Same primitive. GnuPG specifically uses `ky768_bp256` as the
    # internal name for the Kyber-768 + Brainpool P-256 composite.
    'KYBER', 'KY768', 'KY1024', 'KY512',
    # Pre-NIST ML-DSA name (CRYSTALS-Dilithium). NIST renamed it to ML-DSA
    # during standardization (FIPS 204, August 2024) but many tools and
    # crypto libraries still emit the Dilithium name. Same primitive.
    # Must appear before QUANTUM_VULNERABLE so the bare 'DSA' substring
    # (in `DILITHIUM3`) doesn't win first.
    'DILITHIUM2', 'DILITHIUM3', 'DILITHIUM5', 'DILITHIUM',
    # FN-DSA draft (Falcon) — NIST PQC signature finalist, still in draft
    # at FIPS 206. quantum-safe like the other PQC signature families.
    'FALCON-512', 'FALCON-1024', 'FALCON',
    # Pre-standard PQC KEX shipped by OpenSSH 9.0+ (NTRU-Prime hybrid).
    # Replaced by mlkem768x25519-sha256 in OpenSSH 10.0 but still
    # quantum-safe — should not classify as "unknown" just because it's
    # not the NIST-standardized one.
    'SNTRUP761', 'NTRU',
)
QUANTUM_VULNERABLE = (
    'RSA', 'ECDSA', 'ECDH', 'DSA', 'DH',
    'Ed25519', 'Ed448', 'X25519', 'X448',
    # SSH KEX uses curve25519/curve448 naming (not X25519/X448 like TLS).
    # Same underlying Curve25519/448 — quantum-vulnerable to Shor's.
    'CURVE25519', 'CURVE448',
    # OID display names (RFC 5480, RFC 3279) — bare 'EC-' wouldn't match
    # 'id-ecPublicKey' because the substring is 'ECPU' not 'EC-'.
    'ECPUBLICKEY', 'ID-EC',
    # Bare elliptic-curve identifiers (vulnerable on their own to Shor's).
    # nmap-network surfaces names like "ec-256"; OpenSSL/IANA names like
    # prime256v1, secp384r1, P-521 also classify as quantum-vulnerable.
    'PRIME256V1', 'PRIME384V1', 'PRIME521V1',
    'SECP256R1', 'SECP384R1', 'SECP521R1', 'SECP256K1',
    'SECP224R1', 'SECP192R1', 'SECP160R1',
    'P-256', 'P-384', 'P-521', 'P-224', 'P-192',
    'EC-',
    # Classical-algorithm OIDs (RFC 8410, RFC 3279, RFC 5480). Components
    # emitted from raw certificate parses sometimes carry only the OID
    # string, not a human-readable name. Without these the OID falls
    # through to 'unknown' and breaks the dashboard's vulnerable count.
    '1.3.101.112',          # Ed25519     (RFC 8410)
    '1.3.101.113',          # Ed448       (RFC 8410)
    '1.2.840.113549.1.1.1', # rsaEncryption (RFC 3279)
    '1.2.840.10045.2.1',    # ecPublicKey  (RFC 5480)
)
# Word-boundary check for plain "EC" — substring match would false-fire on
# ECDSA/ECDH/SECP*. Used after the substring sweep so explicit names win first.
_BARE_EC_RE = re.compile(r'\bEC\b')
SYMMETRIC_SAFE = (
    'AES', 'AES-GCM',
    # Dashed forms (RFC / OpenSSL display names) and no-dash forms
    # (OpenSSL EVP_MD names like `sha256`, certtool output) — both
    # appear in the wild, classifier must recognize both.
    'SHA-256', 'SHA-384', 'SHA-512', 'SHA3',
    'SHA256', 'SHA384', 'SHA512',
    # ChaCha20 + Poly1305 AEAD — IETF / OpenSSH / TLS 1.3 cipher.
    # Quantum-safe for confidentiality alone (symmetric primitive).
    'CHACHA20-POLY1305', 'CHACHA20',
)
CLASSICAL_WEAK = ('MD5', 'SHA1', 'SHA-1', 'DES', '3DES', 'RC4', 'RC2')


def classify(name):
    """Return one of: 'weak-classical', 'quantum-safe', 'quantum-vulnerable',
    'unknown'. See module docstring for rule order rationale.
    """
    if not name:
        return 'unknown'
    n = name.upper()
    for w in CLASSICAL_WEAK:
        if w.upper() in n:
            return 'weak-classical'
    for s in PQC_ASYMMETRIC:
        if s.upper() in n:
            return 'quantum-safe'
    for v in QUANTUM_VULNERABLE:
        if v.upper() in n:
            return 'quantum-vulnerable'
    if _BARE_EC_RE.search(n):
        return 'quantum-vulnerable'
    for s in SYMMETRIC_SAFE:
        if s.upper() in n:
            return 'quantum-safe'
    return 'unknown'
