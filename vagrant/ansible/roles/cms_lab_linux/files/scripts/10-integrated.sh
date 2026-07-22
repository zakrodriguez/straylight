#!/usr/bin/env bash
# Exercise 10: Integrated end-to-end exercise.
# Sign tarball with RSA-labca + add ML-DSA-65 second signer, then envelope
# the resulting .p7s to two recipients via EnvelopedData. Decrypt + verify
# round-trip on the same platform; cross-platform interop is in validate.sh.
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

# Stage 1: dual-signer SignedData over tarball
$OSSL cms -sign -binary \
    -in inputs/tarball.tar.gz \
    -binary \
    -signer certs/rsa-labca.crt \
    -inkey certs/rsa-labca.key \
    -certfile certs/rsa-labca-chain.crt \
    -out outputs/10a-signed-rsa.p7s \
    -outform DER

$OSSL cms -resign -binary \
    -in outputs/10a-signed-rsa.p7s \
    -inform DER \
    -signer certs/ml-dsa-labca.crt \
    -inkey certs/ml-dsa-labca.key \
    -certfile certs/ml-dsa-labca-chain.crt \
    -md sha256 \
    -out outputs/10b-signed-dual.p7s \
    -outform DER

# Stage 2: envelope the dual-signed .p7s to 2 recipients
$OSSL cms -encrypt -binary \
    -in outputs/10b-signed-dual.p7s \
    -out outputs/10c-final.p7m \
    -outform DER \
    -aes256 \
    -recip certs/self-rsa.crt \
    -recip certs/self-ecdsa.crt

# Stage 3: decrypt + verify round-trip
$OSSL cms -decrypt -binary \
    -in outputs/10c-final.p7m \
    -inform DER \
    -recip certs/self-rsa.crt \
    -inkey certs/self-rsa.key \
    -out outputs/10d-decrypted.p7s

$OSSL cms -verify -binary -purpose any \
    -in outputs/10d-decrypted.p7s \
    -inform DER \
    -CAfile <(cat certs/rsa-labca-chain.crt certs/ml-dsa-labca-chain.crt) \
    -content inputs/tarball.tar.gz \
    -out /dev/null 2>/dev/null \
  && echo "PASS: Exercise 10 — Integrated (dual-sign tarball → envelope → decrypt → verify)" \
  || { echo "FAIL: Exercise 10 verify failed"; exit 1; }
