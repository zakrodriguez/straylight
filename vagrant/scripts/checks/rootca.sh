#!/bin/bash
# scripts/checks/rootca.sh — extracted from validate.sh verbatim.
register_checks_rootca() {
# ─── ROOTCA (two-tier only) ─────────────────────────────────────────────

if ! profile_has rootca; then
    skip_vm rootca "not in profile '$LAB_PROFILE_NAME'"
elif is_running rootca; then
        launch_check rootca run_windows_check rootca "$(cat <<'PS1'
try { Get-Service CertSvc -ErrorAction Stop | Out-Null; Write-Output "PASS: CertSvc (AD CS) running" }
catch { Write-Output "FAIL: CertSvc (AD CS) not running" }

# ── Must NOT be domain-joined ──
$inDomain = (Get-WmiObject Win32_ComputerSystem).PartOfDomain
if (-not $inDomain) {
    Write-Output "PASS: ROOTCA is standalone (not domain-joined)"
} else {
    Write-Output "FAIL: ROOTCA is domain-joined (should be standalone)"
}

# ── PKI-Export files present ──
$certs = Get-ChildItem C:\PKI-Export\*.crt -ErrorAction SilentlyContinue
$crls = Get-ChildItem C:\PKI-Export\*.crl -ErrorAction SilentlyContinue
if ($certs -and $crls) {
    Write-Output "PASS: PKI-Export has $($certs.Count) cert(s) and $($crls.Count) CRL(s)"
} else {
    Write-Output "FAIL: PKI-Export missing certs ($($certs.Count)) or CRLs ($($crls.Count))"
}

# ── CRLF_REVCHECK_IGNORE_OFFLINE cleared ──
$caKey = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*' -ErrorAction SilentlyContinue
$caName = ($caKey | Get-Member -MemberType NoteProperty | Where-Object { $_.Name -notlike 'PS*' } | Select-Object -First 1).Name
$crlFlags = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caName\CA" -ErrorAction SilentlyContinue).CRLFlags
if ($crlFlags -band 4) {
    Write-Output "FAIL: CRLF_REVCHECK_IGNORE_OFFLINE still set (cleanup may have failed)"
} else {
    Write-Output "PASS: CRLF_REVCHECK_IGNORE_OFFLINE cleared"
}
PS1
)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)
$(ps_check_adcs_audit)" "$TMPDIR_VAL/rootca"
else
        skip_vm rootca
fi
}
