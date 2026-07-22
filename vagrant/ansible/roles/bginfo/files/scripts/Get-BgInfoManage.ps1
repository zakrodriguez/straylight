# Get-BgInfoManage.ps1 — Management Workstation fields
param([string]$Field)

switch ($Field) {
    'RSATModules' {
        $caps = Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Rsat' -and $_.State -eq 'Installed' }
        if ($caps) { "$($caps.Count) RSAT tools installed" } else { '0 RSAT tools' }
    }
    'CustomMMC' {
        $pkiMsc = Test-Path 'C:\Software\pki-mgmt.msc'
        $adminMsc = Test-Path 'C:\Software\strayadmin.msc'
        "PKI: $(if($pkiMsc){'OK'}else{'Missing'}) | Admin: $(if($adminMsc){'OK'}else{'Missing'})"
    }
    'CAPing' {
        $domain = $env:USERDNSDOMAIN
        if ($domain) {
            try {
                $result = certutil -ping 2>$null
                if ($result -match 'interface is alive') { 'Alive' } else { 'No response' }
            } catch { 'Error' }
        } else { 'No domain' }
    }
    default { 'Unknown field' }
}
