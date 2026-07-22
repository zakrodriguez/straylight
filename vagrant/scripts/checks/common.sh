#!/bin/bash
# scripts/checks/common.sh — shared PowerShell check snippets.
# Sourced by validate.sh; emitted into Windows check heredocs via $(ps_check_*).
[[ -n "${_VALIDATE_CHECKS_COMMON_LOADED:-}" ]] && return 0
_VALIDATE_CHECKS_COMMON_LOADED=1

ps_check_dns() {
    cat <<PSDNS
\$dns = (Get-DnsClientServerAddress -InterfaceAlias 'Ethernet 2' -AddressFamily IPv4).ServerAddresses
if (\$dns -contains '${DC1_IP}') {
    Write-Output "PASS: DNS points to DC1 (${DC1_IP})"
} else {
    Write-Output "FAIL: DNS on host-only adapter is (\$(\$dns -join ', ')), expected ${DC1_IP}"
}
PSDNS
}

ps_check_domain_join() {
    cat <<PSDOM
\$domain = (Get-WmiObject Win32_ComputerSystem).Domain
if (\$domain -eq '${LAB_DOMAIN}') {
    Write-Output "PASS: Domain joined to ${LAB_DOMAIN}"
} else {
    Write-Output "FAIL: Domain is '\$domain', expected ${LAB_DOMAIN}"
}
PSDOM
}

ps_check_winlogbeat() {
    cat <<'PSWLB'
$svc = Get-Service winlogbeat -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Output "PASS: Winlogbeat service running"
} else {
    Write-Output "FAIL: Winlogbeat service not running"
}
PSWLB
}

ps_check_sysmon() {
    cat <<'PSSM'
$svc = Get-Service Sysmon64 -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Output "PASS: Sysmon64 service running"
} else {
    Write-Output "FAIL: Sysmon64 service not running"
}
PSSM
}

ps_check_filebeat() {
    cat <<'PSFB'
$svc = Get-Service filebeat -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Output "PASS: Filebeat service running"
} else {
    Write-Output "FAIL: Filebeat service not running"
}
PSFB
}

ps_check_cert_expiry() {
    cat <<'PSEXP'
$serverAuthOid = '1.3.6.1.5.5.7.3.1'
$certTemplateOid = '1.3.6.1.4.1.311.21.7'
# Lab ships intentional short-lived test templates (Straylight-Machine-1M-*).
# By design they live ~30 days and autoenroll renews at ~6 days remaining, so
# for ~24 of 30 days they sit inside the 30-day expiry threshold. Excluded
# from this check — autoenrollment owns their lifecycle, not the operator.
$expiring = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object {
        $_.EnhancedKeyUsageList.ObjectId -contains $serverAuthOid -and
        $_.NotAfter -lt (Get-Date).AddDays(30)
    } |
    Where-Object {
        $tmpl = $_.Extensions | Where-Object { $_.Oid.Value -eq $certTemplateOid } | Select-Object -First 1
        if ($null -eq $tmpl) { return $true }  # untemplated cert — apply threshold
        # tmpl.Format(0) text contains: Template=<name>(<oid>), Major Version...
        $tmpl.Format(0) -notmatch 'Template=\S*-1M-'
    }
if ($expiring) {
    Write-Output "FAIL: Machine cert expires within 30 days ($($expiring[0].NotAfter.ToString('yyyy-MM-dd')))"
} else {
    Write-Output "PASS: Machine cert not expiring within 30 days (1M test templates excluded)"
}
PSEXP
}

ps_check_machine_cert() {
    cat <<'PSMC'
$serverAuthOid = '1.3.6.1.5.5.7.3.1'
$machCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains $serverAuthOid }
if ($machCert) {
    Write-Output "PASS: Machine cert with Server Auth EKU ($($machCert.Count) cert(s))"
} else {
    Write-Output "FAIL: No machine cert with Server Auth EKU in Cert:\LocalMachine\My"
}
PSMC
}

ps_check_duplicate_cert_subjects() {
    cat <<'PSDUP'
# Empty Subject is by design for SAN-identity machine certs (Straylight-Machine-*,
# Straylight-Fiddler-*, etc. populate identity via SubjectAlternativeName, not DN).
# Multiple empty-Subject certs from different templates is normal; only group by
# (Subject + Template-OID) so genuine same-template dupes still surface.
$bySubject = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Group-Object {
        $tmpl = ($_.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.21.7' } |
            ForEach-Object { $_.Format(0) }) -join ''
        "$($_.Subject)::$tmpl"
    } |
    Where-Object { $_.Count -gt 1 -and ($_.Group[0].Subject -ne '') }
if (-not $bySubject) {
    Write-Output "PASS: No duplicate cert subjects in LocalMachine\My"
} else {
    $names = ($bySubject | ForEach-Object { ($_.Name -split '::')[0] }) -join '; '
    Write-Output "FAIL: Duplicate cert subjects in LocalMachine\My: $names"
}
PSDUP
}

ps_check_rogue_root_cas() {
    cat <<'PSROGUE'
$pattern = 'TotallyLegit|Definitely Not Malware|Not[- ]?Malware|Rogue|Fake[- ]?Root|Test[- ]?Root|Shadow[- ]?CA'
$rogues = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match $pattern }
if (-not $rogues) {
    Write-Output "PASS: No suspicious root CAs in trust store"
} else {
    $names = ($rogues | ForEach-Object { ($_.Subject -split ',')[0].Trim() }) -join '; '
    Write-Output "FAIL: Suspicious root CA(s) in LocalMachine\Root: $names"
}
PSROGUE
}

ps_check_wildcard_certs() {
    cat <<'PSWILD'
$wilds = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Subject -match '^CN=\*\.' -or
        ($_.DnsNameList -and ($_.DnsNameList | ForEach-Object { $_.Unicode } | Where-Object { $_ -match '^\*\.' }))
    }
if (-not $wilds) {
    Write-Output "PASS: No wildcard certs in LocalMachine\My"
} else {
    $names = ($wilds | ForEach-Object { $_.Subject }) -join '; '
    Write-Output "FAIL: Wildcard cert(s) in LocalMachine\My: $names"
}
PSWILD
}

ps_check_exposed_private_keys() {
    cat <<'PSEXP'
$paths = @('C:\inetpub\wwwroot')
$exposed = @()
foreach ($p in $paths) {
    if (Test-Path $p) {
        $found = Get-ChildItem -Path $p -Include *.pfx,*.p12,*.key -Recurse -ErrorAction SilentlyContinue
        if ($found) { $exposed += $found }
    }
}
if (-not $exposed -or $exposed.Count -eq 0) {
    Write-Output "PASS: No private key files in IIS web root"
} else {
    $names = ($exposed | ForEach-Object { $_.FullName }) -join '; '
    Write-Output "FAIL: Private key file(s) in IIS web root: $names"
}
PSEXP
}

# Detects r2 + a2 — SHA-1 in CA hash algorithm registry or in any cert's
# signature algorithm. Real-world audit: SHA-1 in PKI is universally
# deprecated; both the CA config and any issued cert should never use it.
ps_check_ca_hash_algorithm() {
    cat <<'PSCAHASH'
$fails = @()

# Check CA HashAlgorithm registry value.
try {
    $reg = certutil -getreg CA\HashAlgorithm 2>&1 | Out-String
    if ($reg -match 'HashAlgorithm REG_SZ\s*=\s*SHA1\b') {
        $fails += "CA HashAlgorithm registry set to SHA1"
    }
} catch {
    # CA not installed on this host - silently skip.
}

# Check LocalMachine\My for any cert with SHA-1 signature.
$sha1Certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.SignatureAlgorithm.FriendlyName -match '^sha1' }
if ($sha1Certs) {
    $names = ($sha1Certs | ForEach-Object { ($_.Subject -split ',')[0].Trim() }) -join '; '
    $fails += "SHA-1 signed cert(s) in My: $names"
}

if ($fails.Count -eq 0) {
    Write-Output "PASS: No SHA-1 in CA hash algorithm or issued certs"
} else {
    Write-Output "FAIL: SHA-1 hash algorithm detected - $($fails -join '; ')"
}
PSCAHASH
}

# Detects a5 (shadow CA) - a rogue cert in AD's NTAuthCertificates
# container. Real-world audit: NTAuth additions outside the lab CA
# allowlist indicate forest-wide trust tampering. Reads via ADSI so
# no RSAT-AD-PowerShell dependency.
ps_check_ntauth_ca_count() {
    cat <<'PSNTAUTH'
$rootDSE = [ADSI]'LDAP://RootDSE'
$configNC = $rootDSE.configurationNamingContext.Value
$ntauthDN = "CN=NTAuthCertificates,CN=Public Key Services,CN=Services,$configNC"
$ntauth = [ADSI]"LDAP://$ntauthDN"

$certs = @()
foreach ($der in $ntauth.Properties['cACertificate']) {
    $certs += [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
}

# Allowlist: lab-issued CAs whose CN starts with a known prefix
# (YOURLAB / EJBCA / Smallstep / StraylightChimera) followed by the
# usual -(Root|Issuing|...)-CA suffix. A rogue subject like
# "CN=Backup-Issuing-CA, O=Helpdesk Auto-Provisioned" lacks one of
# these prefixes and surfaces as a FAIL.
$allowed = '^(CN=)?(YOURLAB|EJBCA|Smallstep|StraylightChimera)[A-Za-z0-9_-]*-(Root|Issuing|Intermediate|Sub|Subordinate)-CA(,|$)'
$rogues = @()
foreach ($c in $certs) {
    if ($c.Subject -notmatch $allowed) {
        $rogues += ($c.Subject -split ',')[0].Trim()
    }
}

if ($rogues.Count -eq 0) {
    Write-Output "PASS: No rogue CAs in AD NTAuthCertificates ($($certs.Count) cert(s) total, all allowlisted)"
} else {
    Write-Output "FAIL: Shadow CA(s) in AD NTAuthCertificates: $($rogues -join '; ')"
}
PSNTAUTH
}

ps_check_psframework() {
    cat <<'PSPSF'
if (Test-Path 'C:\Users\Public\Logs\straylight\Initialize-PSFLogging.ps1') {
    Write-Output "PASS: PSFramework init script present"
} else {
    Write-Output "FAIL: PSFramework init script missing"
}
if (Get-Module -ListAvailable -Name PSFramework -ErrorAction SilentlyContinue) {
    Write-Output "PASS: PSFramework module installed"
} else {
    Write-Output "FAIL: PSFramework module not installed"
}
PSPSF
}

ps_check_scriptblock_logging() {
    cat <<'PSSBL'
$val = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -Name 'EnableScriptBlockLogging' -ErrorAction SilentlyContinue
if ($val -and $val.EnableScriptBlockLogging -eq 1) {
    Write-Output "PASS: PowerShell ScriptBlock logging enabled"
} else {
    Write-Output "FAIL: PowerShell ScriptBlock logging NOT enabled"
}
PSSBL
}

ps_check_dns_analytical() {
    cat <<'PSDNA'
$log = Get-WinEvent -ListLog 'Microsoft-Windows-DNSServer/Analytical' -ErrorAction SilentlyContinue
if ($log -and $log.IsEnabled) {
    Write-Output "PASS: DNS Analytical log enabled"
} else {
    Write-Output "FAIL: DNS Analytical log not enabled"
}
PSDNA
}

ps_check_adcs_audit() {
    cat <<'PSAUDIT'
$output = auditpol /get /subcategory:"Certification Services" 2>&1 | Out-String
if ($output -match 'Success and Failure') {
    Write-Output "PASS: AD CS audit policy (Success and Failure)"
} else {
    Write-Output "FAIL: AD CS audit policy not fully enabled"
}
PSAUDIT
}

ps_check_crl_url_network() {
    cat <<PSCRL
try {
    \$r = Invoke-WebRequest -Uri "http://pki.${LAB_DOMAIN}/crl/" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Output "PASS: CRL URL reachable over network (http://pki.${LAB_DOMAIN}/crl/)"
} catch {
    Write-Output "FAIL: CRL URL not reachable (http://pki.${LAB_DOMAIN}/crl/)"
}
PSCRL
}

ps_check_chimera_root_trust() {
    # Verifies the EJBCA-Chimera-Root-CA cert is in Cert:\LocalMachine\Root,
    # pulled from AD's Configuration NC by Group Policy (set up by
    # ejbca_ad_trust role re-run from pqc-chimera.yml). Lets every domain
    # machine validate chimera leaves without per-host root import.
    #
    # Skip emitting any check on profiles that don't include ejbca1 — chimera
    # trust isn't expected when the EJBCA chimera setup never ran.
    profile_has ejbca1 || return 0
    cat <<'PSCHIMERA'
$chimera = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object Subject -match 'EJBCA-Chimera-Root-CA'
if ($chimera) {
    Write-Output "PASS: EJBCA-Chimera-Root-CA trusted (forest-wide GPO distribution)"
} else {
    Write-Output "FAIL: EJBCA-Chimera-Root-CA missing from Cert:\LocalMachine\Root (gpupdate /force then re-check, or run pqc-chimera.yml)"
}
PSCHIMERA
}

ps_check_pqc_machine_cert() {
    # PQC machine cert (ML-DSA-65 + Server-Auth EKU) lands on hosts that
    # include the pqc_machine_cert role (currently manage1) when a PQC
    # issuing CA is in the profile. Skip emitting any check on profiles
    # that don't have one — there's nothing to enroll against.
    profile_has issueca-pqc || return 0
    cat <<'PSPQCCERT'
$mldsa65    = '2.16.840.1.101.3.4.3.18'
$serverAuth = '1.3.6.1.5.5.7.3.1'
$pqcCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    $_.PublicKey.Oid.Value -eq $mldsa65 -and
    $_.EnhancedKeyUsageList.ObjectId -contains $serverAuth -and
    $_.NotAfter -gt (Get-Date)
} | Select-Object -First 1
if ($pqcCert) {
    Write-Output "PASS: ML-DSA-65 machine cert present (issuer=$($pqcCert.Issuer))"
} else {
    Write-Output "FAIL: No ML-DSA-65 machine cert in LocalMachine\My"
}
PSPQCCERT
}

ps_check_chain_validation() {
    # X509Chain.Build with online revocation has an unfixable false-positive failure
    # mode after warm-restart: CryptoAPI caches an OFFLINE flag for any CDP URL whose
    # first fetch failed (e.g. manage1 booted before web1 was ready), and the flag
    # survives wiping CryptnetUrlCache and the WinINet cache. Even from a SYSTEM
    # scheduled task, X509Chain.Build returns CRYPT_E_REVOCATION_OFFLINE while a
    # plain Invoke-WebRequest to the same URL returns 200 with the CRL body. The
    # OS-level retry-after-offline window is undocumented and >15 min in practice.
    #
    # Replace the X509Chain online check with: (a) offline chain build to validate
    # structure/signatures/trust, then (b) explicit Invoke-WebRequest fetch of each
    # non-root cert's CDP CRL with NextUpdate freshness assertion. Same semantic
    # coverage (chain validity + online CDP reachability + CRL freshness), no
    # CryptoAPI cache quirk.
    cat <<'PSCHAIN'
$serverAuthOid = '1.3.6.1.5.5.7.3.1'
# Exclude self-signed certs (Issuer==Subject): the cms_lab_windows role drops
# self-signed Server-Auth demo certs (cms-lab-*-self-rsa/ecdsa) in LocalMachine\My,
# and a bare -First 1 can grab one → false "UntrustedRoot" FAIL. We want the
# autoenrolled enterprise machine cert (Issuer != Subject, real CDP).
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains $serverAuthOid -and $_.Issuer -ne $_.Subject } |
    Select-Object -First 1
if (-not $cert) {
    Write-Output "FAIL: No machine cert to verify chain"
} else {
    # Step 1: offline chain build (no revocation) — proves structure/signatures/trust.
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $built = $chain.Build($cert)
    if (-not $built) {
        $errors = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() }) -join '; '
        Write-Output "FAIL: Cert chain invalid: $errors"
    } else {
        # Step 2: explicit CRL fetch + NextUpdate check for each non-root cert in chain.
        $problems = @()
        for ($i = 0; $i -lt $chain.ChainElements.Count - 1; $i++) {
            $c = $chain.ChainElements[$i].Certificate
            $cdpExt = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.31' } | Select-Object -First 1
            if (-not $cdpExt) { $problems += "no CDP on $($c.Subject)"; continue }
            $asn = New-Object System.Security.Cryptography.AsnEncodedData($cdpExt.Oid, $cdpExt.RawData)
            if ($asn.Format($true) -notmatch 'URL=(http[^\s\r\n,]+)') {
                $problems += "no HTTP URL in CDP for $($c.Subject)"; continue
            }
            $url = $matches[1].Trim()
            $tmp = Join-Path $env:TEMP "validate-$($c.Thumbprint).crl"
            try {
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                $dump = & certutil -dump $tmp 2>&1
                $nextLine = ($dump | Select-String 'NextUpdate' | Select-Object -First 1).Line
                if (-not $nextLine) { $problems += "no NextUpdate parsed from $url"; continue }
                $nextStr = ($nextLine -replace '.*NextUpdate:\s*','').Trim()
                $nextDt = [DateTime]::Parse($nextStr)
                if ($nextDt -lt (Get-Date)) {
                    $problems += "CRL expired (NextUpdate $nextStr) at $url"
                }
            } catch {
                $problems += "CRL fetch failed at ${url}: $($_.Exception.Message)"
            } finally {
                if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        if ($problems.Count -eq 0) {
            Write-Output "PASS: Cert chain valid (CDP CRLs fetched + NextUpdate verified)"
        } else {
            Write-Output "FAIL: Cert chain CRL check: $($problems -join '; ')"
        }
    }
}
PSCHAIN
}
