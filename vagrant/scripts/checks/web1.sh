#!/bin/bash
# scripts/checks/web1.sh — extracted from validate.sh verbatim.
register_checks_web1() {
# ─── WEB1 ────────────────────────────────────────────────────────────────

if is_running web1; then
    launch_check web1 run_windows_check web1 "$(cat <<'PS1'
try { Get-Service W3SVC -ErrorAction Stop | Out-Null; Write-Output "PASS: IIS (W3SVC) service running" }
catch { Write-Output "FAIL: IIS (W3SVC) service not running" }

# ── CRL endpoint ──
try {
    $r = Invoke-WebRequest -Uri http://localhost/crl/ -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Output "PASS: CRL endpoint accessible (HTTP $($r.StatusCode))"
} catch { Write-Output "FAIL: CRL endpoint not accessible at http://localhost/crl/" }

$crlFiles = Get-ChildItem C:\PKI\CRL\*.crl -ErrorAction SilentlyContinue
if ($crlFiles) {
    Write-Output "PASS: CRL files present ($($crlFiles.Count) file(s))"
} else {
    Write-Output "FAIL: No CRL files in C:\PKI\CRL\"
}

# ── AIA endpoint ──
try {
    $r = Invoke-WebRequest -Uri http://localhost/aia/ -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Output "PASS: AIA endpoint accessible (HTTP $($r.StatusCode))"
} catch { Write-Output "FAIL: AIA endpoint not accessible at http://localhost/aia/" }

$aiaFiles = Get-ChildItem C:\PKI\AIA\*.crt -ErrorAction SilentlyContinue
if ($aiaFiles) {
    Write-Output "PASS: AIA files present ($($aiaFiles.Count) file(s))"
} else {
    Write-Output "FAIL: No AIA files in C:\PKI\AIA\"
}

# ── PKI$ SMB share ──
$share = Get-SmbShare -Name 'PKI$' -ErrorAction SilentlyContinue
if ($share) {
    Write-Output "PASS: PKI$ SMB share exists"
} else {
    Write-Output "FAIL: PKI$ SMB share does not exist"
}
PS1
)
$(ps_check_machine_cert)
$(ps_check_chimera_root_trust)
$(ps_check_dns)
$(ps_check_domain_join)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_filebeat)
$(ps_check_cert_expiry)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)
$(ps_check_wildcard_certs)
$(ps_check_exposed_private_keys)" "$TMPDIR_VAL/web1"
else
    skip_vm web1
fi
}
