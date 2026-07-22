#!/usr/bin/env bash
# Exercise 8: AuthEnvelopedData with AES-256-GCM (RFC 5083).
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

$OSSL cms -encrypt -binary \
    -in inputs/hello.txt \
    -out outputs/08-auth-enveloped-aes-gcm.cms \
    -outform DER \
    -aes-256-gcm \
    -recip certs/self-rsa.crt

$OSSL cms -decrypt -binary \
    -in outputs/08-auth-enveloped-aes-gcm.cms \
    -inform DER \
    -recip certs/self-rsa.crt \
    -inkey certs/self-rsa.key \
    -out outputs/08-decrypted-aes-gcm.txt

diff -q outputs/08-decrypted-aes-gcm.txt inputs/hello.txt >/dev/null \
  && echo "PASS: Exercise 8 — AuthEnvelopedData (AES-256-GCM)" \
  || { echo "FAIL: Exercise 8 decrypt mismatch"; exit 1; }
