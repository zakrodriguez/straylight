#!/bin/bash
# scripts/checks/sqlhost1.sh — SQL Server 2022 host for the cert-binding
# labs. No machine-cert / sysmon assertions by design: cert provisioning
# happens inside the walkthroughs (issueca optional), and the playbook
# ships windows_logging + winlogbeat without the sysmon role.
register_checks_sqlhost1() {
# ─── SQLHOST1 ────────────────────────────────────────────────────────────

if is_running sqlhost1; then
    launch_check sqlhost1 run_windows_check sqlhost1 "$(cat <<'PS1'
try {
    $svc = Get-Service MSSQLSERVER -ErrorAction Stop
    if ($svc.Status -eq 'Running') { Write-Output "PASS: MSSQLSERVER service running" }
    else { Write-Output "FAIL: MSSQLSERVER service state: $($svc.Status)" }
} catch { Write-Output "FAIL: MSSQLSERVER service not found" }

$wmi = Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue
if ($wmi -and $wmi.StartName -like '*svc-sql*') {
    Write-Output "PASS: SQL engine runs as svc-sql ($($wmi.StartName))"
} else {
    Write-Output "FAIL: SQL engine account is '$($wmi.StartName)' (expected *svc-sql*)"
}

$listener = Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    Write-Output "PASS: Port 1433 is listening"
} else {
    Write-Output "FAIL: Port 1433 is not listening"
}

$rule = Get-NetFirewallRule -Name 'SQL Server (MSSQLSERVER) TCP 1433' -ErrorAction SilentlyContinue
if (-not $rule) { $rule = Get-NetFirewallRule -DisplayName 'SQL Server*' -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($rule -and $rule.Enabled -eq 'True') {
    Write-Output "PASS: SQL Server firewall rule enabled"
} else {
    Write-Output "FAIL: SQL Server firewall rule missing or disabled"
}
PS1
)
$(ps_check_dns)
$(ps_check_domain_join)
$(ps_check_winlogbeat)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)" "$TMPDIR_VAL/sqlhost1"
fi
}
