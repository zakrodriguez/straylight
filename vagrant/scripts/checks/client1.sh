#!/bin/bash
# scripts/checks/client1.sh — extracted from validate.sh verbatim.
register_checks_client1() {
# ─── CLIENT1 ────────────────────────────────────────────────────────────

if is_running client1; then
    launch_check client1 run_windows_check client1 "$(cat <<'PS1'
# ── Root CA trust ──
$domain = (Get-WmiObject Win32_ComputerSystem).Domain
$parts = $domain.Split('.')
$found = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object {
        $subj = $_.Subject
        $match = $true
        foreach ($p in $parts) { if ($subj -notlike "*$p*") { $match = $false } }
        $match
    }
if ($found) {
    Write-Output "PASS: Root CA cert in trusted store ($($found.Count) cert(s))"
} else {
    Write-Output "FAIL: Root CA cert not found in Cert:\LocalMachine\Root"
}
PS1
)
$(ps_check_machine_cert)
$(ps_check_chimera_root_trust)
$(ps_check_chain_validation)
$(ps_check_crl_url_network)
$(ps_check_dns)
$(ps_check_domain_join)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_cert_expiry)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)
$(ps_check_duplicate_cert_subjects)
$(ps_check_rogue_root_cas)" "$TMPDIR_VAL/client1"
else
    skip_vm client1
fi
}
