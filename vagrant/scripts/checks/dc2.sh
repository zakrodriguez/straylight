#!/bin/bash
# scripts/checks/dc2.sh — extracted from validate.sh verbatim.
register_checks_dc2() {
# ─── DC2 ─────────────────────────────────────────────────────────────────

if is_running dc2; then
    launch_check dc2 run_windows_check dc2 "$(cat <<'PS1'
try { Get-Service NTDS -ErrorAction Stop | Out-Null; Write-Output "PASS: AD DS (NTDS) service running" }
catch { Write-Output "FAIL: AD DS (NTDS) service not running" }

try { Get-Service DNS -ErrorAction Stop | Out-Null; Write-Output "PASS: DNS Server service running" }
catch { Write-Output "FAIL: DNS Server service not running" }

try {
    $repl = repadmin /replsummary 2>&1 | Out-String
    if ($repl -match '\d+ fails' -and $repl -notmatch '\b0 fails\b') {
        Write-Output "FAIL: AD replication has failures"
    } else {
        Write-Output "PASS: AD replication healthy"
    }
} catch { Write-Output "FAIL: Could not check AD replication" }
PS1
)
$(ps_check_dns)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)
$(ps_check_dns_analytical)" "$TMPDIR_VAL/dc2"
fi
}
