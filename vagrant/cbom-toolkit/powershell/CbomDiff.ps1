<#
.SYNOPSIS
    Diff two CycloneDX CBOMs to detect cryptographic changes.

.DESCRIPTION
    Compares components by cryptoProperties content (not bom-ref).
    Reports added/removed certificates, algorithms, keys, and expiry changes.

.PARAMETER Before
    Path to the baseline CBOM JSON file.

.PARAMETER After
    Path to the new CBOM JSON file.

.PARAMETER JsonOutput
    Output results as JSON instead of formatted text.

.EXAMPLE
    .\CbomDiff.ps1 -Before baseline.json -After current.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Before,

    [Parameter(Mandatory)]
    [string]$After,

    [switch]$JsonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────

function Get-ComponentFingerprint {
    param([object]$Component)
    # Identity = cryptoProperties content (stable across scans)
    $cp = $null; try { $cp = $Component.cryptoProperties } catch { }
    if ($cp) {
        return ($cp | ConvertTo-Json -Depth 10 -Compress)
    }
    return $Component.name
}

function Get-AssetType {
    param([object]$Component)
    $t = $null; try { $t = $Component.cryptoProperties.assetType } catch { }
    return $t
}

function Get-CertSummary {
    param([object]$Component)
    $cp = $null; try { $cp = $Component.cryptoProperties.certificateProperties } catch { }
    $subject = '?'; try { $subject = $cp.subjectName } catch { }
    $issuer = '?'; try { $issuer = $cp.issuerName } catch { }
    $expiry = '?'; try { $expiry = $cp.notValidAfter } catch { }
    if (-not $subject) { $subject = $Component.name }
    return "$subject (issuer: $issuer, expires: $expiry)"
}

function Get-KeySummary {
    param([object]$Component)
    $rp = $null; try { $rp = $Component.cryptoProperties.relatedCryptoMaterialProperties } catch { }
    $type = '?'; try { $type = $rp.type } catch { }
    $size = '?'; try { $size = $rp.size } catch { }
    return "$($Component.name) ($type, $size-bit)"
}

function Get-Location {
    param([object]$Component)
    $locs = @()
    try {
        $Component.evidence.occurrences | ForEach-Object {
            $loc = $null; try { $loc = $_.location } catch { }
            if ($loc) { $locs += $loc }
        }
    } catch { }
    if ($locs.Count -gt 0) { return $locs[0] }
    return '?'
}

# ── Load CBOMs ───────────────────────────────────────────────────────────

$bomBefore = Get-Content $Before -Raw | ConvertFrom-Json
$bomAfter  = Get-Content $After  -Raw | ConvertFrom-Json

# ── Index components by fingerprint ──────────────────────────────────────

$beforeIndex = @{}
foreach ($c in @($bomBefore.components)) {
    $fp = Get-ComponentFingerprint $c
    $beforeIndex[$fp] = $c
}

$afterIndex = @{}
foreach ($c in @($bomAfter.components)) {
    $fp = Get-ComponentFingerprint $c
    $afterIndex[$fp] = $c
}

# ── Compute diffs ────────────────────────────────────────────────────────

$added   = [System.Collections.ArrayList]::new()
$removed = [System.Collections.ArrayList]::new()

foreach ($fp in $afterIndex.Keys) {
    if (-not $beforeIndex.ContainsKey($fp)) {
        [void]$added.Add($afterIndex[$fp])
    }
}

foreach ($fp in $beforeIndex.Keys) {
    if (-not $afterIndex.ContainsKey($fp)) {
        [void]$removed.Add($beforeIndex[$fp])
    }
}

# ── Categorize changes ───────────────────────────────────────────────────

$changes = [System.Collections.ArrayList]::new()

# Added components
foreach ($c in $added) {
    $type = Get-AssetType $c
    $detail = switch ($type) {
        'certificate'             { Get-CertSummary $c }
        'algorithm'               { "$($c.name)" }
        'related-crypto-material' { Get-KeySummary $c }
        default                   { $c.name }
    }
    $level = 'INFO'
    # Flag warnings
    if ($type -eq 'algorithm' -and $c.name -match '^(MD5|SHA1|DES|3DES|RC4)') { $level = 'WARN' }
    if ($type -eq 'related-crypto-material') {
        $kt = $null; try { $kt = $c.cryptoProperties.relatedCryptoMaterialProperties.type } catch { }
        if ($kt -eq 'private-key') { $level = 'CRITICAL' }
    }

    [void]$changes.Add([PSCustomObject]@{
        Action   = 'ADDED'
        Level    = $level
        Type     = $type
        Detail   = $detail
        Location = Get-Location $c
    })
}

# Removed components
foreach ($c in $removed) {
    $type = Get-AssetType $c
    $detail = switch ($type) {
        'certificate'             { Get-CertSummary $c }
        'algorithm'               { "$($c.name)" }
        'related-crypto-material' { Get-KeySummary $c }
        default                   { $c.name }
    }
    [void]$changes.Add([PSCustomObject]@{
        Action   = 'REMOVED'
        Level    = 'INFO'
        Type     = $type
        Detail   = $detail
        Location = Get-Location $c
    })
}

# ── Count by type ────────────────────────────────────────────────────────

$addedCerts   = @($added | Where-Object { (Get-AssetType $_) -eq 'certificate' }).Count
$removedCerts = @($removed | Where-Object { (Get-AssetType $_) -eq 'certificate' }).Count
$addedAlgos   = @($added | Where-Object { (Get-AssetType $_) -eq 'algorithm' }).Count
$removedAlgos = @($removed | Where-Object { (Get-AssetType $_) -eq 'algorithm' }).Count
$addedKeys    = @($added | Where-Object { (Get-AssetType $_) -eq 'related-crypto-material' }).Count
$removedKeys  = @($removed | Where-Object { (Get-AssetType $_) -eq 'related-crypto-material' }).Count

# ── Output ───────────────────────────────────────────────────────────────

if ($JsonOutput) {
    [PSCustomObject]@{
        before  = $Before
        after   = $After
        summary = [PSCustomObject]@{
            added_certs    = $addedCerts
            removed_certs  = $removedCerts
            added_algos    = $addedAlgos
            removed_algos  = $removedAlgos
            added_keys     = $addedKeys
            removed_keys   = $removedKeys
            total_changes  = $changes.Count
        }
        changes = $changes
    } | ConvertTo-Json -Depth 5
} else {
    $colors = @{ ADDED = 'Green'; REMOVED = 'Red' }
    $levelColors = @{ INFO = 'White'; WARN = 'Yellow'; CRITICAL = 'Red' }

    if ($changes.Count -eq 0) {
        Write-Host "  No changes detected." -ForegroundColor Green
    } else {
        foreach ($ch in $changes | Sort-Object -Property @{Expression='Level';Descending=$true}, Action, Type) {
            $actionColor = $colors[$ch.Action]
            $prefix = if ($ch.Action -eq 'ADDED') { '+' } else { '-' }
            $warn = ''
            if ($ch.Level -eq 'WARN') { $warn = ' [WEAK]' }
            if ($ch.Level -eq 'CRITICAL') { $warn = ' [CRITICAL]' }
            Write-Host "  $prefix " -ForegroundColor $actionColor -NoNewline
            Write-Host "[$($ch.Type)] " -NoNewline
            Write-Host "$($ch.Detail)" -NoNewline
            if ($warn) { Write-Host $warn -ForegroundColor $levelColors[$ch.Level] -NoNewline }
            Write-Host " ($($ch.Location))" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Summary: " -NoNewline
    Write-Host "+$addedCerts/-$removedCerts certs" -NoNewline
    Write-Host ", +$addedAlgos/-$removedAlgos algos" -NoNewline
    Write-Host ", +$addedKeys/-$removedKeys keys" -NoNewline
    Write-Host " ($($changes.Count) total changes)"
}

if ($changes.Count -gt 0) { exit 1 }
exit 0
