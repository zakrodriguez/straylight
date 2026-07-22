# Get-BgInfoCrypto.ps1 — crypto environment fields
param([string]$Field)

switch ($Field) {
    'OpenSSLVersion' {
        $openssl = Get-Command openssl -ErrorAction SilentlyContinue
        if ($openssl) { (& openssl version 2>$null) -replace 'OpenSSL ', '' } else { 'Not in PATH' }
    }
    'OPENSSL_CONF' {
        $val = [Environment]::GetEnvironmentVariable('OPENSSL_CONF', 'Machine')
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable('OPENSSL_CONF', 'User') }
        if ($val) { $val } else { 'Not set' }
    }
    'SSL_CERT_FILE' {
        $val = [Environment]::GetEnvironmentVariable('SSL_CERT_FILE', 'Machine')
        if ($val) { $val } else { 'Not set' }
    }
    'CURL_CA_BUNDLE' {
        $val = [Environment]::GetEnvironmentVariable('CURL_CA_BUNDLE', 'Machine')
        if ($val) { $val } else { 'Not set' }
    }
    'CryptoProviders' {
        $providers = certutil -csplist 2>$null | Where-Object { $_ -match '^Provider Name:' } |
            ForEach-Object { ($_ -replace 'Provider Name: ', '').Trim() }
        if ($providers) { ($providers | Select-Object -First 5) -join ', ' } else { 'None found' }
    }
    'TPMStatus' {
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            if ($tpm.TpmPresent) { "v$($tpm.ManufacturerVersion) $(if($tpm.TpmReady){'Ready'}else{'Not ready'})" }
            else { 'Not present' }
        } catch { 'Not available' }
    }
    'SecureBoot' {
        try {
            $sb = Confirm-SecureBootUEFI -ErrorAction Stop
            if ($sb) { 'Enabled' } else { 'Disabled' }
        } catch { 'Not supported' }
    }
    'CredentialGuard' {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
        if ($dg -and $dg.SecurityServicesRunning -contains 1) { 'Running' }
        elseif ($dg) { 'Configured but not running' }
        else { 'Not available' }
    }
    'CDPReachable' {
        $domain = $env:USERDNSDOMAIN
        if ($domain) {
            try {
                $r = Invoke-WebRequest -Uri "http://pki.$domain/crl/" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                "Yes ($($r.StatusCode))"
            } catch { 'No' }
        } else { 'No domain' }
    }
    default { 'Unknown field' }
}
