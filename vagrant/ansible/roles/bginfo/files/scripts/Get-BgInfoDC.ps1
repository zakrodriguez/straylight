# Get-BgInfoDC.ps1 — Domain Controller fields
param([string]$Field)

switch ($Field) {
    'FSMORoles' {
        $roles = @()
        $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $me = $env:COMPUTERNAME
        if ($forest.SchemaRoleOwner.Name -match $me) { $roles += 'Schema' }
        if ($forest.NamingRoleOwner.Name -match $me) { $roles += 'Naming' }
        if ($domain.PdcRoleOwner.Name -match $me) { $roles += 'PDC' }
        if ($domain.RidRoleOwner.Name -match $me) { $roles += 'RID' }
        if ($domain.InfrastructureRoleOwner.Name -match $me) { $roles += 'Infra' }
        if ($roles.Count -gt 0) { $roles -join ', ' } else { 'None' }
    }
    'ADFunctionalLevel' {
        $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        "Forest: $($forest.ForestModeLevel) / Domain: $($domain.DomainModeLevel)"
    }
    'DNSZones' {
        $zones = Get-DnsServerZone -ErrorAction SilentlyContinue
        if ($zones) { "$($zones.Count) zones" } else { 'DNS not available' }
    }
    'ADReplication' {
        $result = repadmin /replsummary /bysrc /bydest 2>$null | Select-String 'largest delta'
        if ($result) { $result.ToString().Trim() } else { 'Single DC' }
    }
    'NTAuthCount' {
        $count = (certutil -store -enterprise NTAuth 2>$null | Select-String 'Cert Hash').Count
        "$count CAs trusted"
    }
    'LDAPSCert' {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' -or
                           $_.EnhancedKeyUsageList.Count -eq 0 } |
            Where-Object { $_.Subject -match $env:COMPUTERNAME } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($cert) {
            $days = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            "Bound ($days days)"
        } else { 'Not bound' }
    }
    default { 'Unknown field' }
}
