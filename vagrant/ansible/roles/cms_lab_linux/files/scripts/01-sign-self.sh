#!/usr/bin/env bash
# Exercise 1: SignedData with self-signed RSA cert.
# Produces a detached signature over hello.txt.
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

$OSSL cms -sign -binary \
    -in inputs/hello.txt \
    -signer certs/self-rsa.crt \
    -inkey certs/self-rsa.key \
    -out outputs/01-signed-self.p7s \
    -outform DER

$OSSL cms -verify -binary \
    -in outputs/01-signed-self.p7s \
    -inform DER \
    -CAfile certs/self-rsa.crt \
    -content inputs/hello.txt \
    -out /dev/null 2>/dev/null \
  && echo "PASS: Exercise 1 — SignedData (self-signed RSA, detached)" \
  || { echo "FAIL: Exercise 1 verify failed"; exit 1; }
