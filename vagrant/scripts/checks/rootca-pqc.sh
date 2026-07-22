#!/bin/bash
# scripts/checks/rootca-pqc.sh — extracted from validate.sh verbatim.
register_checks_rootca_pqc() {
# ─── ROOTCA-PQC (pqc-adcs-two-tier only) ────────────────────────────────
# Offline ML-DSA-87 root. Verify CertSvc, standalone, and that the CA's own
# certificate public key is ML-DSA-87 (NIST id-ml-dsa-87 = 2.16.840.1.101.3.4.3.19).

if ! profile_has rootca-pqc; then
    skip_vm rootca-pqc "not in profile '$LAB_PROFILE_NAME'"
elif is_running rootca-pqc; then
        launch_check rootca-pqc run_windows_check rootca-pqc "$(cat <<'PS1'
try { Get-Service CertSvc -ErrorAction Stop | Out-Null; Write-Output "PASS: CertSvc (AD CS) running" }
catch { Write-Output "FAIL: CertSvc (AD CS) not running" }

$inDomain = (Get-WmiObject Win32_ComputerSystem).PartOfDomain
if (-not $inDomain) { Write-Output "PASS: ROOTCA-PQC is standalone (not domain-joined)" }
else { Write-Output "FAIL: ROOTCA-PQC is domain-joined (should be standalone)" }

# ── CA cert public key is ML-DSA-87 ──
$mldsa87Oid = '2.16.840.1.101.3.4.3.19'
$caCert = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $_.Issuer -and $_.Subject -like '*PQC-Root*' } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if ($caCert -and $caCert.PublicKey.Oid.Value -eq $mldsa87Oid) {
    Write-Output "PASS: Root CA public key is ML-DSA-87 ($($caCert.PublicKey.Oid.Value))"
} elseif ($caCert) {
    Write-Output "FAIL: Root CA public key is $($caCert.PublicKey.Oid.Value) (expected ML-DSA-87 $mldsa87Oid)"
} else {
    Write-Output "FAIL: PQC Root CA cert not found in LocalMachine\Root"
}

$certs = Get-ChildItem C:\PKI-Export\*.crt -ErrorAction SilentlyContinue
$crls = Get-ChildItem C:\PKI-Export\*.crl -ErrorAction SilentlyContinue
if ($certs -and $crls) { Write-Output "PASS: PKI-Export has $($certs.Count) cert(s) and $($crls.Count) CRL(s)" }
else { Write-Output "FAIL: PKI-Export missing certs ($($certs.Count)) or CRLs ($($crls.Count))" }
PS1
)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_psframework)" "$TMPDIR_VAL/rootca-pqc"
else
        skip_vm rootca-pqc
fi
}
