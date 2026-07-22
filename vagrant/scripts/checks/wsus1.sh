#!/bin/bash
# scripts/checks/wsus1.sh — extracted from validate.sh verbatim.
register_checks_wsus1() {
# ─── WSUS1 ───────────────────────────────────────────────────────────────

if is_running wsus1; then
    launch_check wsus1 run_windows_check wsus1 "$(cat <<'PS1'
try { Get-Service WsusService -ErrorAction Stop | Out-Null; Write-Output "PASS: WSUS service running" }
catch { Write-Output "FAIL: WSUS service not running" }

# ── WSUS port 8530 ──
$listener = Get-NetTCPConnection -LocalPort 8530 -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    Write-Output "PASS: WSUS port 8530 is listening"
} else {
    Write-Output "FAIL: WSUS port 8530 is not listening"
}

# ── Disk space ──
$drives = @('C')
if (Test-Path D:\) { $drives += 'D' }
foreach ($letter in $drives) {
    $free = (Get-PSDrive $letter).Free
    if ($free -gt 1GB) {
        $freeGB = [math]::Round($free / 1GB, 1)
        Write-Output "PASS: ${letter}: drive space OK (${freeGB} GB free)"
    } else {
        $freeMB = [math]::Round($free / 1MB, 0)
        Write-Output "FAIL: ${letter}: low disk space (${freeMB} MB free)"
    }
}

# ── WSUS DNS record ──
$dnsDomain = (Get-WmiObject Win32_ComputerSystem).Domain
try {
    Resolve-DnsName -Name "wsus.$dnsDomain" -ErrorAction Stop | Out-Null
    Write-Output "PASS: DNS record wsus.$dnsDomain resolves"
} catch {
    Write-Output "FAIL: DNS record wsus.$dnsDomain not found"
}

# Golden-master cache presence (informational)
$susdb = Test-Path 'C:\Software\wsus-cache\SUSDB.mdf'
$content = (Get-ChildItem 'C:\Software\wsus-cache\WsusContent' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
Write-Output "PASS: WSUS cache — SUSDB=$susdb Content=$([bool]$content)"
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
$(ps_check_scriptblock_logging)" "$TMPDIR_VAL/wsus1"
fi
}
