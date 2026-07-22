#!/usr/bin/env bash
# Exercise 3: SignedData with ML-DSA-65 signer from AD CS PQC CA.
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

$OSSL cms -sign -binary \
    -in inputs/hello.txt \
    -signer certs/ml-dsa-labca.crt \
    -inkey certs/ml-dsa-labca.key \
    -certfile certs/ml-dsa-labca-chain.crt \
    -md sha256 \
    -out outputs/03-signed-ml-dsa.p7s \
    -outform DER

$OSSL cms -verify -binary -purpose any \
    -in outputs/03-signed-ml-dsa.p7s \
    -inform DER \
    -CAfile certs/ml-dsa-labca-chain.crt \
    -content inputs/hello.txt \
    -out /dev/null 2>/dev/null \
  && echo "PASS: Exercise 3 — SignedData (ML-DSA-65, lab-CA chain)" \
  || { echo "FAIL: Exercise 3 verify failed"; exit 1; }
