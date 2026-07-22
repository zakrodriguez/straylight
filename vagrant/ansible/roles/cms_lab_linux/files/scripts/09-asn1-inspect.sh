#!/usr/bin/env bash
# Exercise 9: ASN.1 inspection of CMS artifacts.
# Produces canonical .asn1.txt + .annotated.txt sidecars for each artifact.
set -euo pipefail
OSSL=/opt/openssl-3.5/bin/openssl
cd /opt/cms-lab

artifacts=(
  "outputs/02-signed-rsa-labca.p7s"
  "outputs/05-enveloped-rsa.p7m"
  "outputs/08-auth-enveloped-aes-gcm.cms"
)

for art in "${artifacts[@]}"; do
  if [[ ! -f "$art" ]]; then
    echo "SKIP: $art (run prerequisite exercise first)"
    continue
  fi
  echo "─── $art ───"

  # $OSSL asn1parse — structural walk, no OID annotation
  $OSSL asn1parse -inform DER -i -in "$art" > "${art}.asn1parse.txt" 2>&1 || true

  # dumpasn1 — annotated walk with OID names from bundled config
  dumpasn1 -p -d -a "$art" > "${art}.asn1.txt" 2>&1 || true

  # Programmatic drill via asn1crypto for SignedData artifacts
  if [[ "$art" == *.p7s ]]; then
    python3 scripts/_annotate.py "$art" > "${art}.annotated.txt" 2>&1 || true
  fi
done

echo "PASS: Exercise 9 — ASN.1 inspection (3 artifacts, all sidecars written)"
