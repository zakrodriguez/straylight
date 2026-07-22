# Get-BgInfoTomcat.ps1 — Tomcat/Java fields
param([string]$Field)

switch ($Field) {
    'JavaHome' {
        $jh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
        if ($jh) {
            $ver = & "$jh\bin\java.exe" -version 2>&1 | Select-Object -First 1
            "$jh ($ver)"
        } else { 'Not set' }
    }
    'CacertsTruststore' {
        $jh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
        if ($jh) {
            $cacerts = Join-Path $jh 'lib\security\cacerts'
            if (Test-Path $cacerts) {
                $count = (& "$jh\bin\keytool.exe" -list -keystore $cacerts -storepass changeit 2>$null |
                    Select-String 'trustedCertEntry').Count
                "$count certs"
            } else { 'Not found' }
        } else { 'No JAVA_HOME' }
    }
    'TomcatHTTPS' {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            try {
                $r = Invoke-WebRequest -Uri 'https://localhost:8443' -SkipCertificateCheck -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                "Up ($($r.StatusCode))"
            } catch { 'Down or no HTTPS' }
        } else {
            # PS 5.1: -SkipCertificateCheck doesn't exist; override the validation
            # callback and reset in finally to avoid polluting the runspace.
            $prevCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
            try {
                [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                $r = Invoke-WebRequest -Uri 'https://localhost:8443' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                "Up ($($r.StatusCode))"
            } catch {
                'Down or no HTTPS'
            } finally {
                [Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
            }
        }
    }
    default { 'Unknown field' }
}
