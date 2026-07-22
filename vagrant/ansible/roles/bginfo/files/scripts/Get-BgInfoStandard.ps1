# Get-BgInfoStandard.ps1 — standard PKI lab fields for all Windows VMs
param([string]$Field)

switch ($Field) {
    'MachineCert' {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($cert) { $cert.Subject } else { 'None' }
    }
    'MachineCertExpiry' {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($cert) {
            $days = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            "$($cert.NotAfter.ToString('yyyy-MM-dd')) ($days days)"
        } else { 'N/A' }
    }
    'MachineCertTemplate' {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($cert) {
            $ext = $cert.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.21.7' }
            if ($ext) { $ext.Format($false) -replace '^.*Template=', '' -replace '\(.*', '' } else { 'N/A' }
        } else { 'N/A' }
    }
    'MachineCertIssuer' {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($cert) { $cert.Issuer -replace '^CN=', '' -replace ',.*', '' } else { 'N/A' }
    }
    'ExpiredCerts' {
        $count = (Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.NotAfter -lt (Get-Date) }).Count
        "$count"
    }
    'SelfSignedCerts' {
        $count = (Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Issuer -eq $_.Subject } |
            Where-Object { $_.Subject -notmatch 'Microsoft|DigiCert|GlobalSign|Comodo|VeriSign|USERTrust|Baltimore|Starfield|Amazon|Entrust' }).Count
        "$count non-default"
    }
    'SHA1Certs' {
        $count = (Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.SignatureAlgorithm.FriendlyName -match 'sha1' }).Count
        "$count"
    }
    'WeakKeys' {
        $count = 0
        Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.PublicKey.Key.KeySize -lt 2048 -and $_.PublicKey.Key.KeySize -gt 0) { $count++ }
            } catch {}
        }
        "$count"
    }
    'SysmonStatus' {
        $svc = Get-Service Sysmon64 -ErrorAction SilentlyContinue
        if ($svc) { $svc.Status.ToString() } else { 'Not installed' }
    }
    'WinlogbeatStatus' {
        $svc = Get-Service winlogbeat -ErrorAction SilentlyContinue
        if ($svc) { $svc.Status.ToString() } else { 'Not installed' }
    }
    'ObserveReachable' {
        # observe1 :9200 is now loopback-only — probe the Beats TLS ingest
        # port (:9244, served by observe_tls nginx) instead.
        $result = Test-NetConnection -ComputerName $env:OBSERVE_IP -Port 9244 -WarningAction SilentlyContinue -InformationLevel Quiet 2>$null
        if ($result) { 'Yes' } else { 'No' }
    }
    'PwshVersion' {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($pwsh) { (& pwsh --version 2>$null).Trim() } else { 'Not installed' }
    }
    default { 'Unknown field' }
}
