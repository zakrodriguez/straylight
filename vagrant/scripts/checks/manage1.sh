#!/bin/bash
# scripts/checks/manage1.sh — extracted from validate.sh verbatim.
register_checks_manage1() {
# ─── MANAGE1 ────────────────────────────────────────────────────────────

if is_running manage1; then
    launch_check manage1 run_windows_check manage1 "$(cat <<'PS1'
# ── RSAT components ──
# Server-side check (manage1 is Server 2025 Desktop as of 2026-05-22) — features
# come from Install-WindowsFeature, listed by Get-WindowsFeature.
# Server Manager is built-in on Desktop OS, so no separate feature check.
$tools = @(
    @{Name="RSAT-AD-Tools";       Short="ActiveDirectory"},
    @{Name="RSAT-ADCS-Mgmt";      Short="CertificateServices"},
    @{Name="RSAT-DNS-Server";     Short="Dns"},
    @{Name="GPMC";                Short="GroupPolicy"}
)
foreach ($tool in $tools) {
    $feat = Get-WindowsFeature -Name $tool.Name -ErrorAction SilentlyContinue
    if ($feat -and $feat.InstallState -eq 'Installed') {
        Write-Output "PASS: RSAT $($tool.Short) installed"
    } else {
        Write-Output "FAIL: RSAT $($tool.Short) not installed"
    }
}
# Server Manager is built-in on Server 2025 Desktop
if (Test-Path "C:\Windows\System32\ServerManager.exe") {
    Write-Output "PASS: RSAT ServerManager installed"
} else {
    Write-Output "FAIL: RSAT ServerManager not installed"
}

# ── CLI tools on PATH ──
foreach ($cmd in @('openssl.exe', 'dig.exe')) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) {
        Write-Output "PASS: $cmd on PATH"
    } else {
        Write-Output "FAIL: $cmd not found on PATH"
    }
}
PS1
)
$(ps_check_machine_cert)
$(ps_check_pqc_machine_cert)
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
$(ps_check_rogue_root_cas)" "$TMPDIR_VAL/manage1"
fi
}
