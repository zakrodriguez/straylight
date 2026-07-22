#!/bin/bash
# scripts/checks/tomcat1.sh — extracted from validate.sh verbatim.
register_checks_tomcat1() {
# ─── TOMCAT1 ─────────────────────────────────────────────────────────────

if is_running tomcat1; then
    launch_check tomcat1 run_windows_check tomcat1 "$(cat <<'PS1'
try { Get-Service Tomcat10 -ErrorAction Stop | Out-Null; Write-Output "PASS: Tomcat service running" }
catch { Write-Output "FAIL: Tomcat service not running" }

$listener = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    Write-Output "PASS: Port 8080 is listening"
} else {
    Write-Output "FAIL: Port 8080 is not listening"
}

# ── JAVA_HOME / CATALINA_HOME ──
$jh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
if ($jh -and (Test-Path "$jh\bin\java.exe")) {
    Write-Output "PASS: JAVA_HOME set ($jh)"
} else {
    Write-Output "FAIL: JAVA_HOME not set or java.exe missing"
}

$ch = [Environment]::GetEnvironmentVariable('CATALINA_HOME', 'Machine')
if ($ch -and (Test-Path "$ch\bin\catalina.bat")) {
    Write-Output "PASS: CATALINA_HOME set ($ch)"
} else {
    Write-Output "FAIL: CATALINA_HOME not set or catalina.bat missing"
}

# ── Firewall rules ──
foreach ($ruleName in @('Tomcat-HTTP', 'Tomcat-HTTPS')) {
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq 'True') {
        Write-Output "PASS: Firewall rule '$ruleName' enabled"
    } else {
        Write-Output "FAIL: Firewall rule '$ruleName' missing or disabled"
    }
}
PS1
)
$(ps_check_machine_cert)
$(ps_check_chimera_root_trust)
$(ps_check_dns)
$(ps_check_domain_join)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_cert_expiry)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)" "$TMPDIR_VAL/tomcat1"
fi
}
