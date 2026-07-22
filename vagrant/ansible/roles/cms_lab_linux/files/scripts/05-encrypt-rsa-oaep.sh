#!/usr/bin/env bash
# Exercise 5: EnvelopedData with RSA-OAEP recipient (KeyTrans).
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

$OSSL cms -encrypt -binary \
    -in inputs/hello.txt \
    -out outputs/05-enveloped-rsa.p7m \
    -outform DER \
    -aes256 \
    -recip certs/self-rsa.crt \
    -recip certs/rsa-labca.crt

$OSSL cms -decrypt -binary \
    -in outputs/05-enveloped-rsa.p7m \
    -inform DER \
    -recip certs/self-rsa.crt \
    -inkey certs/self-rsa.key \
    -out outputs/05-decrypted-self-rsa.txt

$OSSL cms -decrypt -binary \
    -in outputs/05-enveloped-rsa.p7m \
    -inform DER \
    -recip certs/rsa-labca.crt \
    -inkey certs/rsa-labca.key \
    -out outputs/05-decrypted-rsa-labca.txt

diff -q outputs/05-decrypted-self-rsa.txt inputs/hello.txt >/dev/null \
  && diff -q outputs/05-decrypted-rsa-labca.txt inputs/hello.txt >/dev/null \
  && echo "PASS: Exercise 5 — EnvelopedData (RSA-OAEP, 2 recipients)" \
  || { echo "FAIL: Exercise 5 decrypt mismatch"; exit 1; }
