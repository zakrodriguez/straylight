# Get-BgInfoWeb.ps1 — IIS Web Server fields
param([string]$Field)

Import-Module WebAdministration -ErrorAction SilentlyContinue

switch ($Field) {
    'IISBindings' {
        $bindings = Get-WebBinding -ErrorAction SilentlyContinue
        if ($bindings) {
            ($bindings | ForEach-Object { "$($_.protocol)://$($_.bindingInformation)" }) -join ' | '
        } else { 'No bindings' }
    }
    'HTTPSCertExpiry' {
        $binding = Get-WebBinding -Protocol https -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($binding) {
            $hash = $binding.certificateHash
            if ($hash) {
                $cert = Get-ChildItem "Cert:\LocalMachine\My\$hash" -ErrorAction SilentlyContinue
                if ($cert) {
                    $days = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
                    "$($cert.NotAfter.ToString('yyyy-MM-dd')) ($days days)"
                } else { 'Cert not found' }
            } else { 'No cert bound' }
        } else { 'No HTTPS binding' }
    }
    'CRLAIAVDir' {
        $crl = Get-WebVirtualDirectory -Site 'Default Web Site' -Name 'crl' -ErrorAction SilentlyContinue
        $aia = Get-WebVirtualDirectory -Site 'Default Web Site' -Name 'aia' -ErrorAction SilentlyContinue
        "CRL: $(if($crl){'OK'}else{'Missing'}) | AIA: $(if($aia){'OK'}else{'Missing'})"
    }
    default { 'Unknown field' }
}
