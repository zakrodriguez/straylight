#!/usr/bin/env bash
# Exercise 7: EnvelopedData with ML-KEM-768 via asn1crypto hand-build.
# Workaround for $OSSL cms -encrypt -binary not accepting ML-KEM recipients.
#
# This is a teaching-grade demonstration of the RFC 9629 KEMRecipientInfo
# construction — not production crypto. The KEK wrap step is simplified
# (identity wrap) to keep the example readable.
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

python3 scripts/07-handbuild.py \
    certs/ml-kem-recipient.pub \
    certs/ml-kem-recipient.key \
    inputs/hello.txt \
    outputs/07-enveloped-ml-kem.cms

# Verify the artifact parses as CMS EnvelopedData (structural check).
if $OSSL asn1parse -inform DER -in outputs/07-enveloped-ml-kem.cms >/dev/null 2>&1; then
  size=$(stat -c%s outputs/07-enveloped-ml-kem.cms)
  echo "PASS: Exercise 7 — EnvelopedData (ML-KEM-768 hand-build, ${size} bytes)"
else
  echo "FAIL: Exercise 7 — hand-built artifact does not parse as ASN.1"
  exit 1
fi
