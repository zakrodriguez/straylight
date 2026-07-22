#!/bin/bash
# scripts/checks/ca1.sh — extracted from validate.sh verbatim.
register_checks_ca1() {
# ─── CA1 (one-tier only) ────────────────────────────────────────────────

if ! profile_has ca1; then
    skip_vm ca1 "not in profile '$LAB_PROFILE_NAME'"
elif is_running ca1; then
        launch_check ca1 run_windows_check ca1 "$(cat <<'PS1'
try { Get-Service CertSvc -ErrorAction Stop | Out-Null; Write-Output "PASS: CertSvc (AD CS) running" }
catch { Write-Output "FAIL: CertSvc (AD CS) not running" }

# ── AuditFilter ──
$af = (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' | Get-ItemProperty -Name AuditFilter -ErrorAction SilentlyContinue).AuditFilter
if ($af -eq 127) {
    Write-Output "PASS: CA AuditFilter = 127 (full audit)"
} else {
    Write-Output "FAIL: CA AuditFilter = $af (expected 127)"
}

# ── CDP URL reachable ──
$dnsDomain = (Get-WmiObject Win32_ComputerSystem).Domain
try {
    $r = Invoke-WebRequest -Uri "http://pki.$dnsDomain/crl/" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Output "PASS: CDP URL reachable (http://pki.$dnsDomain/crl/)"
} catch {
    Write-Output "FAIL: CDP URL not reachable (http://pki.$dnsDomain/crl/)"
}

# ── Templates (via schtask for SYSTEM context) ──
$tplScript = @'
$expected = @('Machine','User','WebServer','DomainControllerAuthentication','KerberosAuthentication','Workstation')
$output = certutil -catemplates 2>&1 | Out-String
$results = @()
foreach ($tpl in $expected) {
    if ($output -match [regex]::Escape($tpl)) {
        $results += "PASS: Template '$tpl' published"
    } else {
        $results += "FAIL: Template '$tpl' NOT published"
    }
}
$results | Out-File C:\validate-templates.txt -Encoding ASCII
'@
$tplScript | Out-File C:\validate-tpl.ps1 -Encoding ASCII
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -File C:\validate-tpl.ps1'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'ValidateTemplates' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'ValidateTemplates'
$timeout = 20; $elapsed = 0
while ($elapsed -lt $timeout) {
    Start-Sleep 3; $elapsed += 3
    if ((Get-ScheduledTask -TaskName 'ValidateTemplates').State -eq 'Ready') { break }
}
Get-Content C:\validate-templates.txt -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
Unregister-ScheduledTask -TaskName 'ValidateTemplates' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item C:\validate-tpl.ps1, C:\validate-templates.txt -Force -ErrorAction SilentlyContinue
PS1
)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)
$(ps_check_adcs_audit)
$(ps_check_ca_hash_algorithm)" "$TMPDIR_VAL/ca1"
else
        skip_vm ca1
fi
}
