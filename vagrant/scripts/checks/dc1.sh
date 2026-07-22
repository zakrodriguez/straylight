#!/bin/bash
# scripts/checks/dc1.sh — extracted from validate.sh verbatim.
register_checks_dc1() {
# ─── DC1 ─────────────────────────────────────────────────────────────────

if is_running dc1; then
    launch_check dc1 run_windows_check dc1 "$(cat <<'PS1'
# ── Core services ──
try { Get-Service NTDS -ErrorAction Stop | Out-Null; Write-Output "PASS: AD DS (NTDS) service running" }
catch { Write-Output "FAIL: AD DS (NTDS) service not running" }

try { Get-Service DNS -ErrorAction Stop | Out-Null; Write-Output "PASS: DNS Server service running" }
catch { Write-Output "FAIL: DNS Server service not running" }

# ── DNS integrity ──
try {
    $zones = Get-DnsServerZone -ErrorAction Stop |
        Where-Object { $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated -and
                        $_.ZoneName -notlike '_*' -and $_.ZoneName -notlike '*.in-addr.arpa' }
    $zone = ($zones | Select-Object -First 1).ZoneName
    if ($zone) {
        $natRecords = Get-DnsServerResourceRecord -ZoneName $zone -RRType A -ErrorAction Stop |
            Where-Object { $_.RecordData.IPv4Address.ToString() -like '10.0.2.*' }
        if ($natRecords) {
            $names = ($natRecords | ForEach-Object { $_.HostName }) -join ', '
            Write-Output "FAIL: NAT IP (10.0.2.x) in DNS for: $names"
        } else {
            Write-Output "PASS: No NAT IP pollution in DNS A records"
        }
    }
} catch { Write-Output "FAIL: Could not query DNS records" }

# ── pki DNS record ──
$dnsDomain = (Get-WmiObject Win32_ComputerSystem).Domain
try {
    $r = Resolve-DnsName -Name "pki.$dnsDomain" -Type A -ErrorAction Stop
    Write-Output "PASS: DNS A record pki.$dnsDomain exists"
} catch {
    Write-Output "FAIL: DNS A record pki.$dnsDomain not found"
}

# ── SRV records ──
foreach ($name in @("_kerberos._tcp.$dnsDomain", "_ldap._tcp.$dnsDomain")) {
    try {
        Resolve-DnsName -Name $name -Type SRV -ErrorAction Stop | Out-Null
        $short = $name.Split('.')[0..1] -join '.'
        Write-Output "PASS: SRV record $short resolves"
    } catch {
        $short = $name.Split('.')[0..1] -join '.'
        Write-Output "FAIL: SRV record $short not found"
    }
}

# ── GPOs ──
$gpos = @('PKI - Certificate Autoenrollment', 'Explorer - Default Settings')
foreach ($name in $gpos) {
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if ($gpo) {
        Write-Output "PASS: GPO '$name' exists"
    } else {
        Write-Output "FAIL: GPO '$name' missing"
    }
}

# ── Service accounts ──
$accounts = @('svc-ndes', 'svc-cep', 'svc-ces')
foreach ($acct in $accounts) {
    try {
        Get-ADUser -Identity $acct -ErrorAction Stop | Out-Null
        Write-Output "PASS: Service account '$acct' exists"
    } catch {
        Write-Output "FAIL: Service account '$acct' missing"
    }
}

# ── PKI OUs ──
$domain = (Get-ADDomain).DistinguishedName
foreach ($ou in @("OU=PKI,$domain", "OU=Workstations,$domain")) {
    $short = $ou.Split(',')[0]
    try {
        Get-ADOrganizationalUnit -Identity $ou -ErrorAction Stop | Out-Null
        Write-Output "PASS: $short exists"
    } catch {
        Write-Output "FAIL: $short missing"
    }
}

# ── PKI admin groups ──
$groups = @('PKI Admins', 'Certificate Managers', 'PKI-ServerAdmins', 'PKI-DomainAdmins', 'PKI-EnterpriseAdmins')
foreach ($grp in $groups) {
    $found = Get-ADGroup -Filter "Name -eq '$grp'" -ErrorAction SilentlyContinue
    if ($found) {
        Write-Output "PASS: Group '$grp' exists"
    } else {
        Write-Output "FAIL: Group '$grp' missing"
    }
}
PS1
)
$(ps_check_dns)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_psframework)
$(ps_check_scriptblock_logging)
$(ps_check_dns_analytical)
$(ps_check_rogue_root_cas)
$(ps_check_ntauth_ca_count)" "$TMPDIR_VAL/dc1"
else
    skip_vm dc1
fi
}
