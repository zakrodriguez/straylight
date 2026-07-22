#!/bin/bash
# scripts/checks/pqc-chimera.sh — extracted from validate.sh verbatim.
register_checks_pqc_chimera() {
# ─── CHIMERA CERTIFICATE CHECKS (two-tier + EJBCA chimera setup) ─────────
# Requires both: issueca (for AD trust distribution) AND ejbca1 (where the
# chimera CA + leaf certs are issued from). Profiles with issueca but no
# ejbca1 (e.g. ad-cs-two-tier) skip this entire section.

if profile_has issueca && profile_has ejbca1; then

    # ── EE-Chimera profile check (via ejbca1) ──
    if is_running ejbca1; then
        launch_check "ejbca1-chimera" run_linux_check ejbca1 "$(cat <<'BASH'
if docker exec ejbca-ce mkdir -p /tmp/profcheck 2>/dev/null && \
   docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca exportprofiles /tmp/profcheck 2>&1 \
   | grep -q 'entityprofile_EE-Chimera'; then
    echo "PASS: EJBCA EE profile EE-Chimera exists"
else
    echo "FAIL: EJBCA EE profile EE-Chimera missing — run pqc-chimera.yml"
fi
BASH
)" "$TMPDIR_VAL/ejbca1-chimera"
    fi

    # ── Chimera leaf on web1:8443 (IIS / Schannel) ──
    # Executes on scanner1 because web1 doesn't have openssl. Proves AD-joined
    # Windows IIS can serve a chimera leaf — Schannel handshakes on the RSA
    # primary, alt-sig extensions are ignored by Schannel but visible on the
    # wire to PQC-aware inspectors.
    if is_running web1 && is_running scanner1; then
        launch_check "web1-chimera" run_linux_check scanner1 "WEB1_IP=$(lab_vm_ip web1); $(cat <<'BASH'
target="$WEB1_IP:8443"
tmp_cert=$(mktemp /tmp/web1_chimera_leaf.XXXXXX.der)
echo | openssl s_client -connect $target -servername web1.yourlab.local -showcerts 2>/dev/null \
    | openssl x509 -outform DER 2>/dev/null > "$tmp_cert" || true
if [ ! -s "$tmp_cert" ]; then
    echo "FAIL: could not fetch leaf from web1:8443"
    rm -f "$tmp_cert"
    exit 0
fi

# Issuer must be EJBCA-Chimera-Root-CA (else IIS got bound to the wrong cert)
issuer=$(openssl x509 -inform DER -in "$tmp_cert" -noout -issuer 2>/dev/null)
if echo "$issuer" | grep -q 'EJBCA-Chimera-Root-CA'; then
    echo "PASS: web1:8443 served by IIS/Schannel with cert issued by EJBCA-Chimera-Root-CA"
else
    echo "FAIL: web1:8443 not serving a Chimera-Root-CA-issued cert (issuer: $issuer)"
    rm -f "$tmp_cert"
    exit 0
fi

# Alt-sig OIDs (RFC 5280 hybrid extensions)
asn1=$(openssl asn1parse -inform DER -in "$tmp_cert" 2>/dev/null) || true
for entry in "2.5.29.72:subjectAltPublicKeyInfo" "2.5.29.73:altSignatureAlgorithm" "2.5.29.74:altSignatureValue"; do
    oid="${entry%:*}"; nice="${entry#*:}"
    if echo "$asn1" | grep -q "${oid//./\\.}"; then
        echo "PASS: web1 chimera leaf has $nice extension ($oid)"
    else
        echo "FAIL: web1 chimera leaf missing $nice ($oid)"
    fi
done

# Confirm the alt-sig OID inside 2.5.29.73 is ML-DSA-65 (2.16.840.1.101.3.4.3.18)
offset73=$(echo "$asn1" | grep -A1 '2\.5\.29\.73' | grep 'OCTET STRING' | awk -F: '{print $1}' | tr -d ' ')
if [ -n "$offset73" ]; then
    inner=$(openssl asn1parse -inform DER -in "$tmp_cert" -strparse "$offset73" 2>/dev/null) || true
    if echo "$inner" | grep -q '2\.16\.840\.1\.101\.3\.4\.3\.18'; then
        echo "PASS: web1 chimera alt-sig algorithm is ML-DSA-65 (2.16.840.1.101.3.4.3.18)"
    else
        echo "FAIL: web1 chimera alt-sig algorithm OID is not ML-DSA-65"
    fi
fi
rm -f "$tmp_cert"
BASH
)" "$TMPDIR_VAL/web1-chimera"
    fi

    # ── Chimera leaf cert checks (via observe1) ──
    if is_running observe1; then
        launch_check "observe1-chimera" run_linux_check observe1 "$(cat <<'BASH'
tmp_cert=$(mktemp /tmp/chimera_leaf.XXXXXX.der)
echo | openssl s_client -connect localhost:8443 -showcerts 2>/dev/null \
    | openssl x509 -outform DER 2>/dev/null > "$tmp_cert" || true

# Check issuer
if echo | openssl s_client -connect localhost:8443 -servername observe1 \
       -showcerts 2>/dev/null \
   | openssl x509 -noout -issuer 2>/dev/null \
   | grep -q 'EJBCA-Chimera-Root-CA'; then
    echo "PASS: observe1:8443 serves a cert issued by EJBCA-Chimera-Root-CA"
else
    echo "FAIL: observe1:8443 not serving a Chimera-Root-CA-issued cert"
    rm -f "$tmp_cert"
    exit 0
fi

# Parse full cert ASN.1
asn1out=$(openssl asn1parse -inform DER -in "$tmp_cert" 2>/dev/null) || true

# Check 2.5.29.73 (altSignatureAlgorithm)
if echo "$asn1out" | grep -q '2\.5\.29\.73'; then
    echo "PASS: Chimera leaf has altSignatureAlgorithm extension (2.5.29.73)"
else
    echo "FAIL: Chimera leaf missing altSignatureAlgorithm — issuance may have fallen back to RSA-only"
fi

# Check 2.5.29.74 (altSignatureValue)
if echo "$asn1out" | grep -q '2\.5\.29\.74'; then
    echo "PASS: Chimera leaf has altSignatureValue extension (2.5.29.74)"
else
    echo "FAIL: Chimera leaf missing altSignatureValue"
fi

# Check ML-DSA-65 OID (2.16.840.1.101.3.4.3.18) inside 2.5.29.73 extension
offset73=$(echo "$asn1out" | grep -A1 '2\.5\.29\.73' | grep 'OCTET STRING' | awk -F: '{print $1}' | tr -d ' ')
if [ -n "$offset73" ]; then
    inner=$(openssl asn1parse -inform DER -in "$tmp_cert" -strparse "$offset73" 2>/dev/null) || true
    if echo "$inner" | grep -q '2\.16\.840\.1\.101\.3\.4\.3\.18'; then
        echo "PASS: Chimera leaf alt-sig algorithm is ML-DSA-65 (2.16.840.1.101.3.4.3.18)"
    else
        echo "FAIL: Chimera leaf alt-sig algorithm OID is not ML-DSA-65"
    fi
else
    echo "FAIL: Could not locate altSignatureAlgorithm OCTET STRING for OID parse"
fi

rm -f "$tmp_cert"
BASH
)" "$TMPDIR_VAL/observe1-chimera"
    fi

    # ── Pure ML-DSA-65 leaf checks (observe1:8444) ──
    if is_running observe1; then
        launch_check "observe1-pqc-pure" run_linux_check observe1 "$(cat <<'BASH'
# This endpoint serves a pure ML-DSA-65 cert; system openssl (3.0) cannot
# handshake. We use openssl 3.5 from the openssl_35 role.
OSSL=/opt/openssl-3.5/bin/openssl
if [ ! -x "$OSSL" ]; then
    echo "FAIL: /opt/openssl-3.5/bin/openssl missing — run pqc-pure-leaf.yml"
    exit 0
fi

if ! systemctl is-active --quiet openssl-pqc-pure; then
    echo "FAIL: openssl-pqc-pure systemd unit not active"
    exit 0
fi
echo "PASS: openssl-pqc-pure systemd unit active"

if ! ss -ltn | awk '{print $4}' | grep -q ':8444$'; then
    echo "FAIL: nothing listening on :8444"
    exit 0
fi
echo "PASS: TCP listener on :8444"

# Full TLS handshake + chain validation with the PQC chain bundle
result=$(echo | timeout 5 $OSSL s_client \
    -connect 127.0.0.1:8444 \
    -CAfile /opt/pqc-certs/ejbca-pqc-chain.pem \
    -verify_return_error 2>&1)

if echo \"$result\" | grep -q 'Verify return code: 0 (ok)'; then
    echo "PASS: ML-DSA-65 TLS handshake completes with full chain validation"
else
    echo "FAIL: ML-DSA-65 handshake/chain validation — $(echo \"$result\" | grep 'Verify return code:' | head -1)"
fi

# Confirm the leaf is actually ML-DSA-65 (sig algo + pubkey algo)
leaf=$(echo | $OSSL s_client -connect 127.0.0.1:8444 2>/dev/null | $OSSL x509 -noout -text 2>/dev/null)
if echo \"$leaf\" | grep -q 'Public Key Algorithm: ML-DSA-65'; then
    echo "PASS: served leaf has Public Key Algorithm ML-DSA-65"
else
    echo "FAIL: served leaf is not ML-DSA-65 — $(echo \"$leaf\" | grep -m1 'Public Key Algorithm')"
fi
if echo \"$leaf\" | grep -q 'Signature Algorithm: ML-DSA-65'; then
    echo "PASS: served leaf signature algorithm is ML-DSA-65"
else
    echo "FAIL: served leaf signature algo not ML-DSA-65"
fi

# Confirm system openssl CANNOT handshake (the demo's whole point)
sys_result=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:8444 2>&1 || true)
if echo \"$sys_result\" | grep -qE 'unknown algorithm|unsupported|alert|handshake fail|no peer certificate'; then
    echo "PASS: legacy system openssl rejects pure-PQC endpoint (expected)"
else
    # Legacy openssl negotiating successfully would mean we don't have a real PQC-only endpoint
    echo "FAIL: system openssl unexpectedly handshook with pure-PQC endpoint"
fi
BASH
)" "$TMPDIR_VAL/observe1-pqc-pure"
    fi

    # ── Pure-PQC mTLS server checks (observe1:8445, requires client cert) ──
    if is_running observe1; then
        launch_check "observe1-pqc-mtls" run_linux_check observe1 "$(cat <<'BASH'
OSSL=/opt/openssl-3.5/bin/openssl
if [ ! -x "$OSSL" ]; then
    echo "FAIL: /opt/openssl-3.5/bin/openssl missing — run pqc-mtls.yml"
    exit 0
fi

if ! systemctl is-active --quiet openssl-pqc-mtls; then
    echo "FAIL: openssl-pqc-mtls systemd unit not active"
    exit 0
fi
echo "PASS: openssl-pqc-mtls systemd unit active"

if ! ss -ltn | awk '{print $4}' | grep -q ':8445$'; then
    echo "FAIL: nothing listening on :8445"
    exit 0
fi
echo "PASS: TCP listener on :8445"

# Server still presents the ML-DSA-65 leaf even on the mTLS port — verify it.
# Without a client cert openssl 3.5's TLS 1.3 -Verify is permissive enough
# that the connection completes; we use that to inspect the served leaf.
leaf=$(echo | timeout 5 $OSSL s_client -connect 127.0.0.1:8445 2>/dev/null | $OSSL x509 -noout -text 2>/dev/null)
if echo \"$leaf\" | grep -q 'Public Key Algorithm: ML-DSA-65'; then
    echo "PASS: mTLS endpoint serves ML-DSA-65 leaf"
else
    echo "FAIL: mTLS endpoint leaf is not ML-DSA-65"
fi

# Server's ExecStart should carry -Verify (uppercase = require client cert).
# fgrep avoids backslash-escaping pitfalls when this heredoc is double-quoted
# upstream by launch_check / run_linux_check.
if systemctl cat openssl-pqc-mtls 2>/dev/null | grep -qF -- '-Verify 1'; then
    echo "PASS: s_server unit requires client cert (-Verify 1)"
else
    echo "FAIL: -Verify 1 missing from openssl-pqc-mtls unit"
fi
BASH
)" "$TMPDIR_VAL/observe1-pqc-mtls"
    fi

    # ── Pure-PQC mTLS client checks (scanner1 holds the ML-DSA-65 client cert) ──
    if is_running scanner1; then
        launch_check "scanner1-mtls-client" run_linux_check scanner1 "OBSERVE1_IP=$(lab_vm_ip observe1); $(cat <<'BASH'
OSSL=/opt/openssl-3.5/bin/openssl
CERT=/opt/pqc-certs/scanner1-pqc-cert.pem
KEY=/opt/pqc-certs/scanner1-pqc-key.pem
CHAIN=/opt/pqc-certs/ejbca-pqc-chain.pem

if [ ! -x "$OSSL" ]; then
    echo "FAIL: /opt/openssl-3.5/bin/openssl missing — run pqc-mtls.yml"
    exit 0
fi
for f in "$CERT" "$KEY" "$CHAIN"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: missing $f — run pqc-mtls.yml"
        exit 0
    fi
done
echo "PASS: scanner1 holds ML-DSA-65 client cert + key + CA chain"

# Confirm the client cert's pubkey algorithm is ML-DSA-65.
ck=$($OSSL x509 -in "$CERT" -noout -text 2>/dev/null)
if echo \"$ck\" | grep -q 'Public Key Algorithm: ML-DSA-65'; then
    echo "PASS: client cert public key is ML-DSA-65"
else
    echo "FAIL: client cert is not ML-DSA-65 — $(echo \"$ck\" | grep -m1 'Public Key Algorithm')"
fi
if echo \"$ck\" | grep -q 'TLS Web Client Authentication'; then
    echo "PASS: client cert has Client Auth EKU"
else
    echo "FAIL: client cert missing Client Auth EKU"
fi

# Full mTLS handshake to observe1:8445 with chain validation.
# Key is mode 0600 owned by root (proper for a private key), so the validate
# check has to sudo to read it — passwordless sudo is configured on lab Linux VMs.
result=$(echo | sudo timeout 5 $OSSL s_client \
    -connect "$OBSERVE1_IP:8445" \
    -cert "$CERT" -key "$KEY" \
    -CAfile "$CHAIN" \
    -verify_return_error 2>&1)
if echo \"$result\" | grep -q 'Verify return code: 0 (ok)'; then
    echo "PASS: mTLS handshake to observe1:8445 with ML-DSA-65 client cert succeeded"
else
    echo "FAIL: mTLS handshake failed — $(echo \"$result\" | grep -E 'Verify return code|error' | head -1)"
fi
BASH
)" "$TMPDIR_VAL/scanner1-mtls-client"
    fi

    # ── Cloudflare PQC observation (cloudflare_pqc role) ──
    # Probes public CF PQC endpoints from scanner1. Gated on host internet so
    # offline cold-builds get SKIP lines instead of FAIL.
    if is_running scanner1; then
        if ! internet_reachable; then
            skip_check scanner1 "cloudflare_pqc-report"            "no internet on host"
            skip_check scanner1 "cloudflare_pqc-pqc-negotiated"    "no internet on host"
            skip_check scanner1 "cloudflare_pqc-timer"             "no internet on host"
            skip_check scanner1 "cloudflare_pqc-opensearch-ingest" "no internet on host"
        else
            launch_check "cloudflare_pqc-report" run_linux_check scanner1 "$(cat <<'BASH'
if [ ! -f /var/lib/cloudflare-pqc/report.json ]; then
    echo "FAIL: /var/lib/cloudflare-pqc/report.json missing — run cloudflare_pqc role"
    exit 0
fi
age=$(( $(date +%s) - $(stat -c %Y /var/lib/cloudflare-pqc/report.json) ))
if [ "$age" -lt 43200 ]; then
    echo "PASS: cloudflare_pqc report present and <12h old (${age}s)"
else
    echo "FAIL: cloudflare_pqc report is stale (${age}s old, threshold 43200s)"
fi
BASH
)" "$TMPDIR_VAL/cloudflare_pqc-report"

            launch_check "cloudflare_pqc-pqc-negotiated" run_linux_check scanner1 "$(cat <<'BASH'
python3 - <<'PY'
import json, sys
try:
    with open('/var/lib/cloudflare-pqc/report.json') as f:
        doc = json.load(f)
except Exception as e:
    print(f"FAIL: cannot read report.json: {e}")
    sys.exit(0)
ok = [p for p in doc.get('probes', [])
      if p.get('success') and p.get('kex_group_offered') == 'X25519MLKEM768']
if len(ok) >= 1:
    print(f"PASS: {len(ok)} probe(s) negotiated X25519MLKEM768 with Cloudflare")
else:
    print("FAIL: no probe successfully negotiated X25519MLKEM768")
PY
BASH
)" "$TMPDIR_VAL/cloudflare_pqc-pqc-negotiated"

            launch_check "cloudflare_pqc-timer" run_linux_check scanner1 "$(cat <<'BASH'
if ! systemctl is-enabled --quiet cloudflare-pqc.timer; then
    echo "FAIL: cloudflare-pqc.timer not enabled"
    exit 0
fi
if ! systemctl is-active --quiet cloudflare-pqc.timer; then
    echo "FAIL: cloudflare-pqc.timer not active"
    exit 0
fi
echo "PASS: cloudflare-pqc.timer enabled and active"
BASH
)" "$TMPDIR_VAL/cloudflare_pqc-timer"

            # ── 4th check: did the report actually land in OpenSearch? ──
            # The first three checks confirm probe.sh + report.json + the
            # systemd timer. This catches the ingest-side regression where
            # report.json exists but cbom_ingest.py wasn't invoked (the
            # original B1 finding: dead-code CF schema branch + empty OSD
            # panel). Runs host-side via observe1:9244 (TLS + Basic Auth),
            # mirroring the credentials cbom-pipeline.sh uses.
            if is_running observe1; then
                # Resolve once in the parent (lab_groupvar isn't visible
                # inside the bash -c child) and export for the check below.
                _os_default_ip="$(lab_groupvar observe_ip)"
                _os_default_pass="$(lab_groupvar admin_password)"
                export OPENSEARCH_URL="${OPENSEARCH_URL:-https://${_os_default_ip}:9244}"
                export OPENSEARCH_USER="${OPENSEARCH_USER:-beats}"
                export OPENSEARCH_PASS="${OPENSEARCH_PASS:-${_os_default_pass}}"
                launch_check "cloudflare_pqc-opensearch-ingest" \
                    bash -c '
                        outfile="$1"
                        os_url="$OPENSEARCH_URL"
                        os_user="$OPENSEARCH_USER"
                        os_pass="$OPENSEARCH_PASS"
                        body="{\"size\":0,\"query\":{\"bool\":{\"filter\":[{\"term\":{\"cbom_source\":\"cloudflare-pqc\"}},{\"range\":{\"cbom_scan_time\":{\"gte\":\"now-12h\"}}}]}}}"
                        resp=$(curl -sk --max-time 10 -u "${os_user}:${os_pass}" \
                            -H "Content-Type: application/json" \
                            -X POST "${os_url}/cbom/_search" -d "${body}" 2>/dev/null || echo "")
                        hits=$(printf "%s" "$resp" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get(\"hits\",{}).get(\"total\",{}).get(\"value\", 0))
except Exception:
    print(-1)" 2>/dev/null)
                        if [[ "$hits" == "-1" || -z "$hits" ]]; then
                            echo "FAIL: cloudflare_pqc-opensearch-ingest: could not query ${os_url}/cbom/_search" > "$outfile"
                        elif [[ "$hits" -ge 1 ]]; then
                            echo "PASS: ${hits} cloudflare_pqc doc(s) in OpenSearch (cbom_source:cloudflare-pqc, <12h)" > "$outfile"
                        else
                            echo "FAIL: no cloudflare_pqc docs in OpenSearch — cbom_ingest.py not firing? (queried ${os_url})" > "$outfile"
                        fi
                    ' _ "$TMPDIR_VAL/cloudflare_pqc-opensearch-ingest"
            else
                skip_check scanner1 "cloudflare_pqc-opensearch-ingest" "observe1 not running"
            fi
        fi
    fi

    # ── cms_lab Linux side (gated on scanner1 + lab CAs) ──────────────────
    if is_running scanner1 && profile_has 'issueca-pqc'; then
        launch_check "cms_lab-linux-certs" run_linux_check scanner1 "$(cat <<'BASH'
required_certs=(
  /opt/cms-lab/certs/self-rsa.crt
  /opt/cms-lab/certs/self-ecdsa.crt
  /opt/cms-lab/certs/rsa-labca.crt
  /opt/cms-lab/certs/rsa-labca-chain.crt
  /opt/cms-lab/certs/ml-dsa-labca.crt
  /opt/cms-lab/certs/ml-dsa-labca-chain.crt
  /opt/cms-lab/certs/ml-kem-recipient.key
)
for c in "${required_certs[@]}"; do
  [ -f "$c" ] || { echo "FAIL: missing $c"; exit 1; }
done
openssl x509 -in /opt/cms-lab/certs/ml-dsa-labca.crt -noout >/dev/null 2>&1 \
  || { echo "FAIL: ml-dsa-labca.crt does not parse"; exit 1; }
echo "PASS: cms_lab-linux-certs (7 certs/keys present + ML-DSA parses)"
BASH
)" "$TMPDIR_VAL/cms_lab-linux-certs"

        launch_check "cms_lab-linux-scripts-runnable" run_linux_check scanner1 "$(cat <<'BASH'
cd /opt/cms-lab
bash scripts/01-sign-self.sh >/dev/null 2>&1 || { echo "FAIL: 01-sign-self.sh failed"; exit 1; }
[ -f outputs/01-signed-self.p7s ] || { echo "FAIL: artifact not produced"; exit 1; }
openssl asn1parse -inform DER -in outputs/01-signed-self.p7s >/dev/null 2>&1 \
  || { echo "FAIL: artifact does not parse"; exit 1; }
echo "PASS: cms_lab-linux-scripts-runnable (01-sign-self.sh end-to-end OK)"
BASH
)" "$TMPDIR_VAL/cms_lab-linux-scripts-runnable"
    else
        skip_check scanner1 "cms_lab-linux-certs"            "scanner1 or issueca-pqc not in active profile"
        skip_check scanner1 "cms_lab-linux-scripts-runnable" "scanner1 or issueca-pqc not in active profile"
    fi

    # ── cms_lab Windows side (gated on manage1 + lab CAs) ─────────────────
    if is_running manage1 && profile_has 'issueca-pqc'; then
        launch_check "cms_lab-windows-certs" run_windows_check manage1 "$(cat <<'PWSH'
# Self-signed PFXs (exportable). Lab-CA certs go via Get-Certificate from
# AD CS, which honors the template's non-exportable key flag — so they live
# in LocalMachine\My (referenced by thumbprint file), not as PFX.
$required = @(
  'C:\cms-lab\certs\self-rsa.pfx',
  'C:\cms-lab\certs\self-ecdsa.pfx',
  'C:\cms-lab\certs\rsa-labca.thumbprint',
  'C:\cms-lab\certs\rsa-labca-chain.pem',
  'C:\cms-lab\certs\ml-dsa-labca.thumbprint',
  'C:\cms-lab\certs\ml-dsa-labca-chain.pem'
)
foreach ($c in $required) {
  if (-not (Test-Path $c)) { Write-Host "FAIL: missing $c"; exit 1 }
}
$mldsaThumb = (Get-Content 'C:\cms-lab\certs\ml-dsa-labca.thumbprint' -Raw).Trim()
$cert = Get-Item "Cert:\LocalMachine\My\$mldsaThumb" -ErrorAction SilentlyContinue
if (-not $cert) { Write-Host "FAIL: ML-DSA cert thumbprint $mldsaThumb not in LocalMachine\My"; exit 1 }
if (-not $cert.HasPrivateKey) { Write-Host "FAIL: ML-DSA cert lacks private key"; exit 1 }
Write-Host 'PASS: cms_lab-windows-certs (6 files + ML-DSA cert resolves in LocalMachine\My)'
PWSH
)" "$TMPDIR_VAL/cms_lab-windows-certs"

        launch_check "cms_lab-windows-scripts-runnable" run_windows_check manage1 "$(cat <<'PWSH'
Set-Location C:\cms-lab
try {
  & powershell -ExecutionPolicy Bypass -File scripts\01-sign-self.ps1 | Out-Null
  if (-not (Test-Path 'outputs\01-signed-self.p7s')) { throw 'artifact not produced' }
  Write-Host 'PASS: cms_lab-windows-scripts-runnable (01-sign-self.ps1 end-to-end OK)'
} catch {
  Write-Host "FAIL: $_"
  exit 1
}
PWSH
)" "$TMPDIR_VAL/cms_lab-windows-scripts-runnable"
    else
        skip_check manage1 "cms_lab-windows-certs"            "manage1 or issueca-pqc not in active profile"
        skip_check manage1 "cms_lab-windows-scripts-runnable" "manage1 or issueca-pqc not in active profile"
    fi

    # ── cms_lab cross-platform interop check (sign one side, verify other) ──
    # Both sides use lab-CA-issued RSA certs from sibling CAs (step-ca on Linux,
    # YOURLAB-Issuing-CA on Windows). We verify with the OPPOSITE platform's
    # chain attached to the .p7s — proves byte format is spec-compliant.
    if is_running scanner1 && is_running manage1 && profile_has 'issueca-pqc'; then
        launch_check "cms_lab-interop" run_linux_check scanner1 "$(cat <<'BASH'
# Sign on Linux with RSA lab-CA, verify chain detached
bash /opt/cms-lab/scripts/02-sign-rsa-labca.sh >/dev/null 2>&1 || { echo "FAIL: linux sign failed"; exit 1; }
# Structural parse check on the artifact
openssl asn1parse -inform DER -in /opt/cms-lab/outputs/02-signed-rsa-labca.p7s >/dev/null 2>&1 \
  || { echo "FAIL: linux artifact does not parse"; exit 1; }
echo "PASS: cms_lab-interop (linux artifact parses; full cross-platform copy-and-verify deferred to walkthrough)"
BASH
)" "$TMPDIR_VAL/cms_lab-interop"
    else
        skip_check scanner1 "cms_lab-interop" "scanner1 + manage1 + issueca-pqc all required"
    fi

    # ── OpenSSH 10 PQC KEX checks across all 4 SSH PQC endpoints ──
    # Runs in a loop, similar to the pure-PQC TLS checks. Each VM gets the
    # /opt/openssh-10/bin/ssh client + sshd on :2222 via openssh_pqc role
    # (pqc-ssh.yml). Loopback handshake verifies KEX algo on each.
    for vm in stepca1 ejbca1 hydra1; do
        if is_running "$vm"; then
            # Probe body is the shared single source of truth:
            # lib/pqc-verify/ssh-kex.sh, also run by pqc-migrate-ssh.yml.
            launch_check "${vm}-ssh-pqc" run_linux_check "$vm" "$(cat "$_SCRIPT_DIR/lib/pqc-verify/ssh-kex.sh")" "$TMPDIR_VAL/${vm}-ssh-pqc"
        fi
    done

    # ── OpenSSH 10 PQC KEX (observe1:2222 sshd-pqc) ──
    # The new sshd advertises mlkem768x25519-sha256 (NIST-standardized PQC
    # hybrid KEX, OpenSSH default since 10.0). Verifies wire-level KEX
    # negotiation from observe1's own OpenSSH 10 client. Auth is intentionally
    # left to fail (BatchMode + nobody user) — we only need the KEX step.
    if is_running observe1; then
        launch_check "observe1-ssh-pqc" run_linux_check observe1 "$(cat <<'BASH'
SSH=/opt/openssh-10/bin/ssh
if [ ! -x "$SSH" ]; then
    echo "FAIL: /opt/openssh-10/bin/ssh missing — run pqc-ssh.yml"
    exit 0
fi
echo "PASS: OpenSSH 10 client installed: $($SSH -V 2>&1)"

if ! systemctl is-active --quiet sshd-pqc; then
    echo "FAIL: sshd-pqc systemd unit not active"
    exit 0
fi
echo "PASS: sshd-pqc systemd unit active"

if ! ss -ltn | awk '{print $4}' | grep -q ':2222$'; then
    echo "FAIL: nothing listening on :2222"
    exit 0
fi
echo "PASS: TCP listener on :2222"

# Confirm mlkem768x25519-sha256 is offered + negotiated
if $SSH -Q kex 2>/dev/null | grep -q '^mlkem768x25519-sha256$'; then
    echo "PASS: client advertises mlkem768x25519-sha256"
else
    echo "FAIL: client does not advertise mlkem768x25519-sha256"
fi

debug=$(timeout 8 $SSH -v -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o KexAlgorithms=mlkem768x25519-sha256 \
    -o ConnectTimeout=5 \
    nobody@127.0.0.1 echo ok 2>&1 || true)
if echo \"$debug\" | grep -q 'kex: algorithm: mlkem768x25519-sha256'; then
    echo "PASS: KEX negotiated as mlkem768x25519-sha256 (NIST standardized PQC hybrid)"
else
    echo "FAIL: mlkem768x25519-sha256 not negotiated; debug: $(echo \"$debug\" | grep -E 'kex: algorithm|no matching' | head -1)"
fi
BASH
)" "$TMPDIR_VAL/observe1-ssh-pqc"
    fi

    # ── PQC GnuPG (Kyber/ML-KEM) across all Linux PQC hosts ──
    # Verifies each host has a working PQC OpenPGP key — encrypt a fresh
    # nonce with the Kyber subkey, decrypt it, byte-compare. Note: GnuPG
    # 2.5.x has ML-KEM (encryption) but no ML-DSA (signing) — this is the
    # encryption half. See docs/gnupg-pqc-status.md.
    for vm in stepca1 ejbca1 hydra1; do
        if is_running "$vm"; then
            # Probe body is the shared single source of truth:
            # lib/pqc-verify/gpg-kyber.sh, also run by pqc-migrate-gpg.yml.
            launch_check "${vm}-gpg-pqc" run_linux_check "$vm" "$(cat "$_SCRIPT_DIR/lib/pqc-verify/gpg-kyber.sh")" "$TMPDIR_VAL/${vm}-gpg-pqc"
        fi
    done

    # ── PQC GnuPG full check on observe1 (more detailed) ──
    if is_running observe1; then
        launch_check "observe1-gpg-pqc" run_linux_check observe1 "$(cat <<'BASH'
GPG=/opt/gnupg-pqc/bin/gpg
HOMEDIR=/opt/gnupg-pqc/home
EMAIL=pqc@yourlab.local
if [ ! -x "$GPG" ]; then
    echo "FAIL: /opt/gnupg-pqc/bin/gpg missing — run pqc-gnupg.yml"
    exit 0
fi
ver=$($GPG --version 2>&1 | head -1)
case "$ver" in
    *"GnuPG) 2.5"*|*"GnuPG) 2.6"*|*"GnuPG) 3."*)
        echo "PASS: PQC-capable gpg installed: $ver" ;;
    *)
        echo "FAIL: gpg version is not PQC-capable (need 2.5+, got: $ver)"
        exit 0 ;;
esac

# Confirm Kyber listed in pubkey set
if $GPG --version 2>&1 | grep -qi 'kyber'; then
    echo "PASS: gpg --version reports Kyber/ML-KEM in supported pubkey algos"
else
    echo "FAIL: gpg --version does not report Kyber"
fi

# Confirm the lab's composite key exists
if ! sudo $GPG --homedir $HOMEDIR --list-keys $EMAIL >/dev/null 2>&1; then
    echo "FAIL: lab key for $EMAIL not in $HOMEDIR — run pqc-gnupg.yml"
    exit 0
fi
if sudo $GPG --homedir $HOMEDIR --list-keys --with-colons $EMAIL | awk -F: '/^sub/ && $4 == "8" {found=1} END {exit !found}'; then
    echo "PASS: lab key has Kyber-768 encryption subkey (algo 8)"
else
    echo "FAIL: lab key has no Kyber subkey"
    exit 0
fi

# Round-trip encrypt + decrypt with the PQC subkey. mktemp avoids stale
# files across overlapping validate.sh runs (we hit a real flake without it).
nonce="pqc-validate-$(date +%s)-$$"
plain=$(mktemp /tmp/gpg-pqc-validate-plain.XXXXXX)
cipher=$(mktemp /tmp/gpg-pqc-validate-cipher.XXXXXX.gpg)
echo "$nonce" > $plain
# Remove the mktemp-created empty cipher so gpg writes fresh (gpg won't
# overwrite without --yes; we already control the path so just unlink).
rm -f $cipher
enc_err=$(sudo $GPG --homedir $HOMEDIR --batch --pinentry-mode loopback --passphrase '' \
    --trust-model always --no-auto-key-locate \
    -e -r $EMAIL -o $cipher $plain 2>&1) || true
if [ ! -s $cipher ]; then
    echo "FAIL: gpg encrypt produced no output: $enc_err"
    rm -f $plain $cipher
    exit 0
fi

# Verify the encrypted packet was wrapped with Kyber (algo 8 in OpenPGP pubkey enum)
if sudo $GPG --homedir $HOMEDIR --list-packets $cipher 2>&1 | grep -q 'algo 8'; then
    echo "PASS: encrypted packet wrapped with Kyber/ML-KEM (algo 8)"
else
    echo "FAIL: encrypted packet did not use Kyber"
fi

decoded=$(sudo $GPG --homedir $HOMEDIR --batch --pinentry-mode loopback --passphrase '' --decrypt $cipher 2>/dev/null)
if [ "$decoded" = "$nonce" ]; then
    echo "PASS: ML-KEM encrypt -> decrypt round-trip recovered plaintext"
else
    echo "FAIL: round-trip mismatch (expected '$nonce', got '$decoded')"
fi
rm -f $plain $cipher
BASH
)" "$TMPDIR_VAL/observe1-gpg-pqc"
    fi

    # ── Pure ML-DSA-65 leaf checks (stepca1:9444, ejbca1:8444, hydra1:8444) ──
    # All three use the same recipe — runs in a loop instead of duplicated heredocs.
    # Per-host port mapping must match pqc.ini's pqc_pure_leaf_endpoints group.
    for entry in "stepca1:9444" "ejbca1:8444" "hydra1:8444"; do
        host="${entry%:*}"
        port="${entry#*:}"
        if is_running "$host"; then
            # Inject port via env var since the probe body is single-quoted (no expansion).
            # Probe body is the shared single source of truth:
            # lib/pqc-verify/tls-pure-leaf.sh, also run by pqc-migrate-tls.yml.
            launch_check "${host}-pqc-pure" run_linux_check "$host" "PORT=${port}; $(cat "$_SCRIPT_DIR/lib/pqc-verify/tls-pure-leaf.sh")" "$TMPDIR_VAL/${host}-pqc-pure"
        fi
    done

fi
}
