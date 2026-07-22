#!/usr/bin/env bash
# Exercise 2: SignedData with lab-CA-issued RSA cert (chain attached).
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

$OSSL cms -sign -binary \
    -in inputs/hello.txt \
    -signer certs/rsa-labca.crt \
    -inkey certs/rsa-labca.key \
    -certfile certs/rsa-labca-chain.crt \
    -out outputs/02-signed-rsa-labca.p7s \
    -outform DER

$OSSL cms -verify -binary -purpose any \
    -in outputs/02-signed-rsa-labca.p7s \
    -inform DER \
    -CAfile certs/rsa-labca-chain.crt \
    -content inputs/hello.txt \
    -out /dev/null 2>/dev/null \
  && echo "PASS: Exercise 2 — SignedData (lab-CA RSA, chain attached)" \
  || { echo "FAIL: Exercise 2 verify failed"; exit 1; }
