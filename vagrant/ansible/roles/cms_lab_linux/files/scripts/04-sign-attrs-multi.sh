#!/usr/bin/env bash
# Exercise 4: SignedData with signed attributes + second signer (multi-signer pattern).
# Primary signer: RSA lab-CA. Second signer: ML-DSA-65 lab-CA.
# OpenSSL CLI doesn't support RFC 5652 countersignatures directly; -resign
# adds a parallel SignerInfo at the SignedData level, which is the more
# common "multi-signer" pattern in practice.
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

# Primary signature (default -sign includes signing-time, message-digest,
# content-type signed attributes).
$OSSL cms -sign -binary \
    -in inputs/hello.txt \
    -signer certs/rsa-labca.crt \
    -inkey certs/rsa-labca.key \
    -certfile certs/rsa-labca-chain.crt \
    -out outputs/04a-primary.p7s \
    -outform DER

# Add a second signer over the same content.
$OSSL cms -resign -binary \
    -in outputs/04a-primary.p7s \
    -inform DER \
    -signer certs/ml-dsa-labca.crt \
    -inkey certs/ml-dsa-labca.key \
    -certfile certs/ml-dsa-labca-chain.crt \
    -md sha256 \
    -out outputs/04-signed-multi.p7s \
    -outform DER

$OSSL cms -verify -binary -purpose any \
    -in outputs/04-signed-multi.p7s \
    -inform DER \
    -CAfile <(cat certs/rsa-labca-chain.crt certs/ml-dsa-labca-chain.crt) \
    -content inputs/hello.txt \
    -out /dev/null 2>/dev/null \
  && echo "PASS: Exercise 4 — SignedData (signed attrs + multi-signer)" \
  || { echo "FAIL: Exercise 4 verify failed"; exit 1; }
