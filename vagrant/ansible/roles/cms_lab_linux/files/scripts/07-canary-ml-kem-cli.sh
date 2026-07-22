#!/usr/bin/env bash
# Exercise 7 canary: try $OSSL cms -encrypt -binary with ML-KEM recipient.
# EXPECTED to fail today (RFC 9629 KEMRecipientInfo not in mainline CLI).
# If it ever succeeds, Exercise 7 walkthrough needs revision.
set -uo pipefail  # NOT -e — we expect a failure
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

output=$("$OSSL" cms -encrypt -binary \
    -in inputs/hello.txt \
    -recip certs/ml-kem-recipient.pub \
    -out /tmp/canary-ml-kem.p7m \
    -outform DER 2>&1 || true)

if echo "$output" | grep -qE "unsupported|error|unknown|cannot|invalid|fail"; then
  echo "PASS: ML-KEM CLI canary still failing (workaround section stays valid)"
  exit 0
else
  echo "ALERT: $OSSL cms -encrypt -binary now accepts ML-KEM — Exercise 7 walkthrough needs revision"
  echo "Canary output:"
  echo "$output"
  exit 1
fi
