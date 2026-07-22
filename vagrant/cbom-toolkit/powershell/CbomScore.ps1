<#
.SYNOPSIS
    PQC readiness scoring per VM from a CycloneDX CBOM.

.DESCRIPTION
    Classifies each crypto component as quantum-vulnerable, quantum-safe,
    or weak-classical, groups by VM, and produces a per-VM scorecard with
    migration targets.

.PARAMETER Path
    Path to CycloneDX CBOM JSON file.

.PARAMETER JsonOutput
    Output results as JSON instead of formatted text.

.EXAMPLE
    .\CbomScore.ps1 -Path cbom-one-tier-deduped.json
    .\CbomScore.ps1 -Path cbom.json -JsonOutput
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [switch]$JsonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── PQC classification ───────────────────────────────────────────────────

$quantumVulnerable = @('RSA', 'ECDSA', 'ECDH', 'DSA', 'DH', 'Ed25519', 'Ed448', 'X25519', 'X448')
$quantumSafe = @('AES', 'SHA-256', 'SHA-384', 'SHA-512', 'SHA3', 'ML-KEM', 'ML-DSA', 'SLH-DSA', 'XMSS', 'LMS')
$classicalWeak = @('MD5', 'SHA1', 'SHA-1', 'DES', '3DES', 'RC4', 'RC2')

function Get-PqcClass {
    param([string]$Name)
    foreach ($w in $classicalWeak) {
        if ($Name -match [regex]::Escape($w)) { return 'weak-classical' }
    }
    foreach ($v in $quantumVulnerable) {
        if ($Name -match [regex]::Escape($v)) { return 'quantum-vulnerable' }
    }
    foreach ($s in $quantumSafe) {
        if ($Name -match [regex]::Escape($s)) { return 'quantum-safe' }
    }
    return 'unknown'
}

function Get-Grade {
    param([double]$SafePercent)
    if ($SafePercent -ge 80) { return 'GREEN' }
    if ($SafePercent -ge 50) { return 'AMBER' }
    return 'RED'
}

# ── Load CBOM ────────────────────────────────────────────────────────────

if (-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

$bom = Get-Content $Path -Raw | ConvertFrom-Json
$components = @($bom.components)

# ── Classify and group by VM ─────────────────────────────────────────────

$vmData = @{}

foreach ($c in $components) {
    $name = $null; try { $name = $c.name } catch { }
    if (-not $name) { continue }

    $assetType = $null
    try { $assetType = $c.cryptoProperties.assetType } catch { }

    # Only score algorithms and key material (not certs directly)
    if ($assetType -ne 'algorithm' -and $assetType -ne 'related-crypto-material') { continue }

    $pqcClass = Get-PqcClass $name

    # Extract VM from location
    $vmName = '?'
    try {
        $occ = $c.evidence.occurrences
        if ($occ -and $occ.Count -gt 0) {
            $loc = $null; try { $loc = $occ[0].location } catch { }
            if ($loc -and $loc -match '^([^/]+)/') {
                $vmName = $Matches[1]
            }
        }
    } catch { }

    if (-not $vmData.ContainsKey($vmName)) {
        $vmData[$vmName] = @{
            total      = 0
            vulnerable = 0
            safe       = 0
            weak       = 0
            unknown    = 0
            migration  = [System.Collections.ArrayList]::new()
        }
    }

    $vmData[$vmName].total++
    switch ($pqcClass) {
        'quantum-vulnerable' {
            $vmData[$vmName].vulnerable++
            $target = "$name ($assetType)"
            if ($vmData[$vmName].migration -notcontains $target) {
                [void]$vmData[$vmName].migration.Add($target)
            }
        }
        'quantum-safe'       { $vmData[$vmName].safe++ }
        'weak-classical'     { $vmData[$vmName].weak++ }
        'unknown'            { $vmData[$vmName].unknown++ }
    }
}

# ── Build scorecards ─────────────────────────────────────────────────────

$scorecards = [System.Collections.ArrayList]::new()

foreach ($vm in ($vmData.Keys | Sort-Object)) {
    $d = $vmData[$vm]
    $classified = $d.total - $d.unknown
    $safePercent = if ($classified -gt 0) { [Math]::Round(($d.safe / $classified) * 100, 1) } else { 0 }
    $vulnPercent = if ($classified -gt 0) { [Math]::Round(($d.vulnerable / $classified) * 100, 1) } else { 0 }
    $weakPercent = if ($classified -gt 0) { [Math]::Round(($d.weak / $classified) * 100, 1) } else { 0 }

    [void]$scorecards.Add([PSCustomObject]@{
        VM           = $vm
        Total        = $d.total
        Vulnerable   = $d.vulnerable
        Safe         = $d.safe
        Weak         = $d.weak
        Unknown      = $d.unknown
        SafePercent  = $safePercent
        VulnPercent  = $vulnPercent
        WeakPercent  = $weakPercent
        Grade        = Get-Grade $safePercent
        Migration    = @($d.migration | Sort-Object)
    })
}

# Lab-wide summary
$labTotal = ($vmData.Values | ForEach-Object { $_.total } | Measure-Object -Sum).Sum
$labVuln  = ($vmData.Values | ForEach-Object { $_.vulnerable } | Measure-Object -Sum).Sum
$labSafe  = ($vmData.Values | ForEach-Object { $_.safe } | Measure-Object -Sum).Sum
$labWeak  = ($vmData.Values | ForEach-Object { $_.weak } | Measure-Object -Sum).Sum
$labUnknown = ($vmData.Values | ForEach-Object { $_.unknown } | Measure-Object -Sum).Sum
$labClassified = $labTotal - $labUnknown
$labSafePercent = if ($labClassified -gt 0) { [Math]::Round(($labSafe / $labClassified) * 100, 1) } else { 0 }

# ── Output ───────────────────────────────────────────────────────────────

if ($JsonOutput) {
    [PSCustomObject]@{
        file       = $Path
        lab_summary = [PSCustomObject]@{
            total       = $labTotal
            vulnerable  = $labVuln
            safe        = $labSafe
            weak        = $labWeak
            unknown     = $labUnknown
            safe_pct    = $labSafePercent
            grade       = Get-Grade $labSafePercent
        }
        vms = $scorecards
    } | ConvertTo-Json -Depth 5
} else {
    $gradeColors = @{ GREEN = 'Green'; AMBER = 'Yellow'; RED = 'Red' }

    Write-Host ""
    Write-Host "  PQC Readiness Scorecard" -ForegroundColor Cyan
    Write-Host "  ═══════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # Table header
    $fmt = "  {0,-12} {1,6} {2,6} {3,6} {4,6} {5,8} {6,6}"
    Write-Host ($fmt -f 'VM', 'Total', 'Vuln', 'Safe', 'Weak', 'Safe %', 'Grade')
    Write-Host "  $('-' * 58)"

    foreach ($sc in $scorecards) {
        $gradeColor = $gradeColors[$sc.Grade]
        Write-Host ("  {0,-12} {1,6} {2,6} {3,6} {4,6} {5,7}% " -f
            $sc.VM, $sc.Total, $sc.Vulnerable, $sc.Safe, $sc.Weak, $sc.SafePercent) -NoNewline
        Write-Host ("{0,6}" -f $sc.Grade) -ForegroundColor $gradeColor
    }

    Write-Host "  $('-' * 58)"
    $labGrade = Get-Grade $labSafePercent
    Write-Host ("  {0,-12} {1,6} {2,6} {3,6} {4,6} {5,7}% " -f
        'LAB TOTAL', $labTotal, $labVuln, $labSafe, $labWeak, $labSafePercent) -NoNewline
    Write-Host ("{0,6}" -f $labGrade) -ForegroundColor $gradeColors[$labGrade]

    # Migration targets per VM
    Write-Host ""
    Write-Host "  Migration Targets" -ForegroundColor Cyan
    Write-Host "  ─────────────────" -ForegroundColor Cyan
    foreach ($sc in $scorecards) {
        if ($sc.Migration.Count -eq 0) { continue }
        Write-Host "  $($sc.VM):" -ForegroundColor Yellow
        foreach ($m in $sc.Migration) {
            Write-Host "    → $m" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

exit 0
