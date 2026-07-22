# Get-BgInfoCA.ps1 — Certificate Authority fields
param([string]$Field)

switch ($Field) {
    'CACertExpiry' {
        $info = certutil -CAInfo 2>$null
        $expiry = $info | Select-String 'CA Expiration' | Select-Object -First 1
        if ($expiry) { $expiry.ToString().Trim() -replace '.*-- ', '' } else { 'N/A' }
    }
    'IssuedCerts' {
        $total = (certutil -view -restrict "Disposition=20" -out RequestID 2>$null | Select-String 'Row').Count
        $revoked = (certutil -view -restrict "Disposition=21" -out RequestID 2>$null | Select-String 'Row').Count
        "Active: $total / Revoked: $revoked"
    }
    'CRLFreshness' {
        $period = (certutil -getreg CA\CRLPeriod 2>$null | Select-String 'REG_SZ').ToString() -replace '.*= ', ''
        $units = (certutil -getreg CA\CRLPeriodUnits 2>$null | Select-String 'REG_DWORD').ToString() -replace '.*= ', '' -replace ' .*', ''
        "$units $period"
    }
    'CRLDelta' {
        $period = (certutil -getreg CA\CRLDeltaPeriod 2>$null | Select-String 'REG_SZ').ToString() -replace '.*= ', ''
        $units = (certutil -getreg CA\CRLDeltaPeriodUnits 2>$null | Select-String 'REG_DWORD').ToString() -replace '.*= ', '' -replace ' .*', ''
        "$units $period"
    }
    'MaxValidity' {
        $period = (certutil -getreg CA\ValidityPeriod 2>$null | Select-String 'REG_SZ').ToString() -replace '.*= ', ''
        $units = (certutil -getreg CA\ValidityPeriodUnits 2>$null | Select-String 'REG_DWORD').ToString() -replace '.*= ', '' -replace ' .*', ''
        "$units $period"
    }
    'AuditFilter' {
        $raw = (certutil -getreg CA\AuditFilter 2>$null | Select-String 'REG_DWORD').ToString() -replace '.*= ', '' -replace ' .*', ''
        $val = [int]$raw
        $flags = @()
        if ($val -band 1) { $flags += 'Start/Stop' }
        if ($val -band 2) { $flags += 'Backup/Restore' }
        if ($val -band 4) { $flags += 'Issue/Deny' }
        if ($val -band 8) { $flags += 'Revoke' }
        if ($val -band 16) { $flags += 'Settings' }
        if ($val -band 32) { $flags += 'Retrieve' }
        if ($flags.Count -gt 0) { $flags -join ', ' } else { 'None' }
    }
    'PublishedTemplates' {
        $templates = certutil -catemplates 2>$null | Where-Object { $_ -match ':' }
        if ($templates) { "$($templates.Count) templates" } else { '0 templates' }
    }
    'ActiveCSP' {
        $provider = (certutil -getreg CA\CSP\Provider 2>$null | Select-String 'REG_SZ').ToString() -replace '.*= ', ''
        $provider.Trim()
    }
    'KeyAlgorithm' {
        $info = certutil -CAInfo 2>$null
        $key = $info | Select-String 'CA Key' | Select-Object -First 1
        if ($key) { $key.ToString().Trim() -replace '.*-- ', '' } else { 'N/A' }
    }
    'ESCIndicators' {
        $esc1 = certutil -catemplates 2>$null | Where-Object { $_ -match 'CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT' }
        $warnings = @()
        if ($esc1 -and $esc1.Count -gt 0) { $warnings += "ESC1:$($esc1.Count)" }
        if ($warnings.Count -gt 0) { $warnings -join ' | ' } else { 'Clean' }
    }
    default { 'Unknown field' }
}
