# Set-LabBgInfo.ps1 — generates BGInfo wallpaper with PKI lab dashboard
# Called at logon via registry Run key
param(
    [string]$Role = 'GENERIC',
    [string]$Topology = '',
    [string]$ObserveIP = '',
    [string]$ScriptDir = 'C:\ProgramData\straylight\bginfo\scripts'
)

$env:OBSERVE_IP = $ObserveIP

# Rolling error log (silent helper failures land here, not on the wallpaper)
$errorLog = 'C:\ProgramData\straylight\bginfo\errors.log'
New-Item -ItemType Directory -Force -Path (Split-Path $errorLog) | Out-Null
function Write-BgInfoError {
    param([string]$Helper, [string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $errorLog -Value "$stamp [$Helper] $Message"
    try {
        $info = Get-Item $errorLog -ErrorAction SilentlyContinue
        if ($info -and $info.Length -gt 1MB) {
            $tail = Get-Content $errorLog -Tail 500
            Set-Content -Path $errorLog -Value $tail
        }
    } catch {}
}

# Collect field values
$fields = [ordered]@{}
$fields['VM Role'] = $Role
if ($Topology) { $fields['Topology'] = $Topology }
$fields['Host Name'] = $env:COMPUTERNAME
$fields['Domain'] = $env:USERDNSDOMAIN
$fields['IP Address'] = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(10\.0\.2|127\.)' } |
    Select-Object -First 1).IPAddress
$fields['OS'] = (Get-CimInstance Win32_OperatingSystem).Caption -replace 'Microsoft ', ''
$fields['Uptime'] = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToString('d\.hh\:mm')

# Standard PKI fields
$stdScript = Join-Path $ScriptDir 'Get-BgInfoStandard.ps1'
if (Test-Path $stdScript) {
    foreach ($f in @('MachineCert','MachineCertExpiry','MachineCertTemplate','MachineCertIssuer',
                     'ExpiredCerts','SHA1Certs','WeakKeys')) {
        try {
            $val = & $stdScript -Field $f 2>$null
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = if ($val) { $val } else { 'N/A' }
        } catch {
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = 'N/A'
            Write-BgInfoError -Helper "Standard/$f" -Message $_.Exception.Message
        }
    }
}

# Crypto fields
$cryptoScript = Join-Path $ScriptDir 'Get-BgInfoCrypto.ps1'
if (Test-Path $cryptoScript) {
    foreach ($f in @('OpenSSLVersion','OPENSSL_CONF','CryptoProviders','TPMStatus','SecureBoot','PwshVersion')) {
        try {
            $val = & $cryptoScript -Field $f 2>$null
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = if ($val) { $val } else { 'N/A' }
        } catch {
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = 'N/A'
            Write-BgInfoError -Helper "Crypto/$f" -Message $_.Exception.Message
        }
    }
}

# Monitoring fields
if (Test-Path $stdScript) {
    foreach ($f in @('SysmonStatus','WinlogbeatStatus','ObserveReachable')) {
        try {
            $val = & $stdScript -Field $f 2>$null
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = if ($val) { $val } else { 'N/A' }
        } catch {
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = 'N/A'
            Write-BgInfoError -Helper "Monitoring/$f" -Message $_.Exception.Message
        }
    }
}

# Role-specific fields
$roleScript = Join-Path $ScriptDir 'Get-BgInfoRole.ps1'
if (Test-Path $roleScript) {
    $roleFields = switch ($Role) {
        'DC'      { @('FSMORoles','ADFunctionalLevel','DNSZones','ADReplication','NTAuthCount','LDAPSCert') }
        'CA'      { @('CACertExpiry','IssuedCerts','CRLFreshness','MaxValidity','AuditFilter','PublishedTemplates','ActiveCSP','KeyAlgorithm','ESCIndicators') }
        'ROOTCA'  { @('CACertExpiry','CRLFreshness','ActiveCSP','KeyAlgorithm') }
        'ISSUECA' { @('CACertExpiry','IssuedCerts','CRLFreshness','MaxValidity','AuditFilter','PublishedTemplates','ActiveCSP','KeyAlgorithm','ESCIndicators') }
        'WEB'     { @('IISBindings','HTTPSCertExpiry','CRLAIAVDir') }
        'MANAGE'  { @('RSATModules','CustomMMC','CAPing') }
        'TOMCAT'  { @('JavaHome','CacertsTruststore','TomcatHTTPS') }
        default   { @() }
    }
    foreach ($f in $roleFields) {
        try {
            $val = & $roleScript -Field $f 2>$null
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = if ($val) { $val } else { 'N/A' }
        } catch {
            $label = ($f -creplace '([A-Z])', ' $1').Trim()
            $fields[$label] = 'N/A'
            Write-BgInfoError -Helper "Role/$f" -Message $_.Exception.Message
        }
    }
}

# Build wallpaper text
$text = "=== STRAYLIGHT PKI LAB === $Role`n"
$text += "=" * 50 + "`n`n"
foreach ($entry in $fields.GetEnumerator()) {
    $text += "{0,-25} {1}`n" -f "$($entry.Key):", $entry.Value
}

# Write info file (useful for scripts/debugging)
$infoFile = 'C:\ProgramData\straylight\bginfo\lab-info.txt'
$text | Out-File -FilePath $infoFile -Encoding UTF8 -Force
