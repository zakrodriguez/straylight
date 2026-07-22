#!/usr/bin/env bash
# Exercise 6: EnvelopedData with ECDH-ES recipient (KeyAgree).
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

$OSSL cms -encrypt -binary \
    -in inputs/hello.txt \
    -out outputs/06-enveloped-ecdh.p7m \
    -outform DER \
    -aes256 \
    -recip certs/self-ecdsa.crt

$OSSL cms -decrypt -binary \
    -in outputs/06-enveloped-ecdh.p7m \
    -inform DER \
    -recip certs/self-ecdsa.crt \
    -inkey certs/self-ecdsa.key \
    -out outputs/06-decrypted-ecdh.txt

diff -q outputs/06-decrypted-ecdh.txt inputs/hello.txt >/dev/null \
  && echo "PASS: Exercise 6 — EnvelopedData (ECDH-ES, KeyAgree branch)" \
  || { echo "FAIL: Exercise 6 decrypt mismatch"; exit 1; }
