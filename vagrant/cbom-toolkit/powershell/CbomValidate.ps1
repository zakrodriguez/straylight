<#
.SYNOPSIS
    Validate a CycloneDX 1.6 CBOM beyond JSON schema — crypto-specific correctness.

.DESCRIPTION
    Checks bom-ref integrity, required certificate fields, algorithm properties,
    orphaned components, key size sanity, and weak algorithm detection.

.PARAMETER Path
    Path to CycloneDX CBOM JSON file.

.PARAMETER JsonOutput
    Output results as JSON instead of formatted text.

.EXAMPLE
    .\CbomValidate.ps1 -Path .\cbom-one-tier-deduped.json
    .\CbomValidate.ps1 -Path .\cbom.json -JsonOutput
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [switch]$JsonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Result tracking ──────────────────────────────────────────────────────

$results = [System.Collections.ArrayList]::new()

function Add-Result {
    param(
        [ValidateSet('PASS','WARN','FAIL')]
        [string]$Level,
        [string]$Check,
        [string]$Message
    )
    [void]$results.Add([PSCustomObject]@{
        Level   = $Level
        Check   = $Check
        Message = $Message
    })
}

# ── Load CBOM ────────────────────────────────────────────────────────────

if (-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

try {
    $raw = Get-Content $Path -Raw
    $bom = $raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse JSON: $_"
    exit 1
}

# ── Check 1: Required top-level fields ───────────────────────────────────

$requiredTop = @('bomFormat', 'specVersion', 'serialNumber', 'version', 'components')
foreach ($field in $requiredTop) {
    if ($null -ne $bom.$field) {
        Add-Result -Level PASS -Check 'top-level' -Message "Field '$field' present"
    } else {
        Add-Result -Level FAIL -Check 'top-level' -Message "Required field '$field' missing"
    }
}

if ($bom.bomFormat -ne 'CycloneDX') {
    Add-Result -Level FAIL -Check 'top-level' -Message "bomFormat is '$($bom.bomFormat)', expected 'CycloneDX'"
} else {
    Add-Result -Level PASS -Check 'top-level' -Message "bomFormat is 'CycloneDX'"
}

if ($bom.specVersion -and [version]$bom.specVersion -lt [version]'1.6') {
    Add-Result -Level WARN -Check 'top-level' -Message "specVersion $($bom.specVersion) predates CBOM support (1.6+)"
} elseif ($bom.specVersion) {
    Add-Result -Level PASS -Check 'top-level' -Message "specVersion $($bom.specVersion)"
}

# ── Build lookup tables ──────────────────────────────────────────────────

$components = @($bom.components)
$refMap = @{}
foreach ($c in $components) {
    if ($c.'bom-ref') {
        $refMap[$c.'bom-ref'] = $c
    }
}

$dependencies = @()
if ($bom.dependencies) {
    $dependencies = @($bom.dependencies)
}

# Categorize components
$certs = @($components | Where-Object { $_.cryptoProperties.assetType -eq 'certificate' })
$algos = @($components | Where-Object { $_.cryptoProperties.assetType -eq 'algorithm' })
$keys  = @($components | Where-Object { $_.cryptoProperties.assetType -eq 'related-crypto-material' })

Add-Result -Level PASS -Check 'inventory' -Message "Components: $($components.Count) total ($($certs.Count) certs, $($algos.Count) algorithms, $($keys.Count) keys)"

# ── Check 2: bom-ref uniqueness ──────────────────────────────────────────

$allRefs = @($components | ForEach-Object { $_.'bom-ref' } | Where-Object { $_ })
$uniqueRefs = @($allRefs | Select-Object -Unique)
if ($allRefs.Count -eq $uniqueRefs.Count) {
    Add-Result -Level PASS -Check 'bom-ref' -Message "All $($allRefs.Count) bom-refs are unique"
} else {
    $dupes = $allRefs.Count - $uniqueRefs.Count
    Add-Result -Level FAIL -Check 'bom-ref' -Message "$dupes duplicate bom-ref values found"
}

$missingRef = @($components | Where-Object { -not $_.'bom-ref' })
if ($missingRef.Count -gt 0) {
    Add-Result -Level FAIL -Check 'bom-ref' -Message "$($missingRef.Count) components missing bom-ref"
} else {
    Add-Result -Level PASS -Check 'bom-ref' -Message "All components have bom-ref"
}

# ── Check 3: Dependency integrity ────────────────────────────────────────

$depErrors = 0
foreach ($dep in $dependencies) {
    if (-not $refMap.ContainsKey($dep.ref)) {
        Add-Result -Level FAIL -Check 'deps' -Message "Dependency ref '$($dep.ref)' not found in components"
        $depErrors++
    }
    foreach ($target in @($dep.dependsOn)) {
        if (-not $refMap.ContainsKey($target)) {
            Add-Result -Level FAIL -Check 'deps' -Message "dependsOn ref '$($target)' not found in components"
            $depErrors++
        }
    }
}
if ($depErrors -eq 0 -and $dependencies.Count -gt 0) {
    Add-Result -Level PASS -Check 'deps' -Message "All $($dependencies.Count) dependency refs resolve"
} elseif ($dependencies.Count -eq 0) {
    Add-Result -Level WARN -Check 'deps' -Message "No dependencies defined"
}

# ── Check 4: Certificate required fields ─────────────────────────────────

$certMissing = 0
$certOk = 0
$requiredCertFields = @('subjectName', 'notValidBefore', 'notValidAfter')
foreach ($cert in $certs) {
    $cp = $null
    try { $cp = $cert.cryptoProperties.certificateProperties } catch { }
    if (-not $cp) {
        Add-Result -Level FAIL -Check 'cert-fields' -Message "Certificate '$($cert.name)' missing certificateProperties"
        $certMissing++
        continue
    }
    $missing = @()
    foreach ($f in $requiredCertFields) {
        $val = $null
        try { $val = $cp.$f } catch { }
        if (-not $val) { $missing += $f }
    }
    if ($missing.Count -gt 0) {
        $certMissing++
    } else {
        $certOk++
    }
}
if ($certOk -gt 0) {
    Add-Result -Level PASS -Check 'cert-fields' -Message "$certOk/$($certs.Count) certificates have all required fields"
}
if ($certMissing -gt 0) {
    Add-Result -Level WARN -Check 'cert-fields' -Message "$certMissing/$($certs.Count) certificates missing fields"
}

# ── Check 5: Certificate algorithm refs ──────────────────────────────────

$sigRefOk = 0; $sigRefBad = 0
$pkRefOk = 0; $pkRefBad = 0
foreach ($cert in $certs) {
    $cp = $null
    try { $cp = $cert.cryptoProperties.certificateProperties } catch { }
    if (-not $cp) { continue }

    $sigRef = $null; try { $sigRef = $cp.signatureAlgorithmRef } catch { }
    if ($sigRef) {
        if ($refMap.ContainsKey($sigRef)) { $sigRefOk++ } else { $sigRefBad++ }
    }

    $pkRef = $null; try { $pkRef = $cp.subjectPublicKeyRef } catch { }
    if ($pkRef) {
        if ($refMap.ContainsKey($pkRef)) { $pkRefOk++ } else { $pkRefBad++ }
    }
}
if ($sigRefOk -gt 0) {
    Add-Result -Level PASS -Check 'cert-refs' -Message "$sigRefOk signatureAlgorithmRefs resolve"
}
if ($sigRefBad -gt 0) {
    Add-Result -Level FAIL -Check 'cert-refs' -Message "$sigRefBad signatureAlgorithmRefs point to missing components"
}
if ($pkRefOk -gt 0) {
    Add-Result -Level PASS -Check 'cert-refs' -Message "$pkRefOk subjectPublicKeyRefs resolve"
}
if ($pkRefBad -gt 0) {
    Add-Result -Level FAIL -Check 'cert-refs' -Message "$pkRefBad subjectPublicKeyRefs point to missing components"
}

# ── Check 6: Algorithm properties ────────────────────────────────────────

$validPrimitives = @('pke','mac','hash','signature','kdf','kem','ke','cipher','block-cipher',
                      'stream-cipher','aead','combiner','xof','other','unknown')
$algoPrimOk = 0; $algoPrimBad = 0; $algoPrimMissing = 0
foreach ($algo in $algos) {
    $ap = $null; try { $ap = $algo.cryptoProperties.algorithmProperties } catch { }
    if (-not $ap) {
        $algoPrimMissing++
        continue
    }
    $prim = $null; try { $prim = $ap.primitive } catch { }
    if ($prim) {
        if ($validPrimitives -contains $prim) {
            $algoPrimOk++
        } else {
            Add-Result -Level WARN -Check 'algo-props' -Message "Algorithm '$($algo.name)' has unknown primitive '$prim'"
            $algoPrimBad++
        }
    } else {
        $algoPrimMissing++
    }
}
if ($algoPrimOk -gt 0) {
    Add-Result -Level PASS -Check 'algo-props' -Message "$algoPrimOk/$($algos.Count) algorithms have valid primitive"
}
if ($algoPrimMissing -gt 0) {
    Add-Result -Level WARN -Check 'algo-props' -Message "$algoPrimMissing/$($algos.Count) algorithms missing primitive"
}

# ── Check 7: Key sizes ───────────────────────────────────────────────────

$keySizeOk = 0; $keySizeBad = 0; $keySizeMissing = 0
foreach ($key in $keys) {
    $rp = $null; try { $rp = $key.cryptoProperties.relatedCryptoMaterialProperties } catch { }
    if (-not $rp) { continue }
    $size = $null; try { $size = $rp.size } catch { }
    if ($null -eq $size) {
        $keySizeMissing++
    } elseif ($size -le 0) {
        Add-Result -Level FAIL -Check 'key-size' -Message "Key '$($key.name)' has invalid size: $size"
        $keySizeBad++
    } else {
        $keySizeOk++
    }
}
if ($keySizeOk -gt 0) {
    Add-Result -Level PASS -Check 'key-size' -Message "$keySizeOk/$($keys.Count) keys have valid sizes"
}
if ($keySizeMissing -gt 0) {
    Add-Result -Level WARN -Check 'key-size' -Message "$keySizeMissing/$($keys.Count) keys missing size"
}

# ── Check 8: Weak algorithms ────────────────────────────────────────────

$weakAlgos = @('MD5', 'MD5-RSA', 'SHA1', 'SHA1-RSA', 'DES', '3DES', 'RC4', 'RC2')
$weakFound = @()
foreach ($algo in $algos) {
    if ($weakAlgos -contains $algo.name) {
        $weakFound += $algo.name
    }
}
$weakFound = @($weakFound | Select-Object -Unique)
if ($weakFound.Count -gt 0) {
    Add-Result -Level WARN -Check 'weak-algo' -Message "Weak algorithms present: $($weakFound -join ', ')"
} else {
    Add-Result -Level PASS -Check 'weak-algo' -Message "No weak algorithms detected"
}

# Weak key sizes (RSA < 2048)
$weakKeys = [System.Collections.ArrayList]::new()
foreach ($key in $keys) {
    $rp = $null; try { $rp = $key.cryptoProperties.relatedCryptoMaterialProperties } catch { }
    if (-not $rp) { continue }
    $sz = $null; try { $sz = $rp.size } catch { }
    if ($sz -and $sz -lt 2048 -and $key.name -match 'RSA') {
        [void]$weakKeys.Add($key)
    }
}
if ($weakKeys.Count -gt 0) {
    $sizes = @($weakKeys | ForEach-Object {
        try { $_.cryptoProperties.relatedCryptoMaterialProperties.size } catch { }
    } | Select-Object -Unique | Sort-Object)
    Add-Result -Level WARN -Check 'weak-key' -Message "$($weakKeys.Count) RSA keys < 2048 bits (sizes: $($sizes -join ', '))"
} else {
    Add-Result -Level PASS -Check 'weak-key' -Message "No RSA keys < 2048 bits"
}

# ── Check 9: Private keys detected ──────────────────────────────────────

$privateKeys = [System.Collections.ArrayList]::new()
foreach ($key in $keys) {
    $t = $null; try { $t = $key.cryptoProperties.relatedCryptoMaterialProperties.type } catch { }
    if ($t -eq 'private-key') { [void]$privateKeys.Add($key) }
}
if ($privateKeys.Count -gt 0) {
    $locations = @($privateKeys | ForEach-Object {
        $_.evidence.occurrences | ForEach-Object { $_.location }
    }) -join ', '
    Add-Result -Level WARN -Check 'private-key' -Message "$($privateKeys.Count) private key(s) found: $locations"
} else {
    Add-Result -Level PASS -Check 'private-key' -Message "No private keys detected"
}

# ── Check 10: Certificate expiry ─────────────────────────────────────────

$now = Get-Date
$expiringSoon = 0
$expired = 0
foreach ($cert in $certs) {
    $cp = $null; try { $cp = $cert.cryptoProperties.certificateProperties } catch { }
    $nva = $null; try { $nva = $cp.notValidAfter } catch { }
    if (-not $cp -or -not $nva) { continue }
    try {
        $expiry = [datetime]::Parse($nva)
        if ($expiry -lt $now) {
            $expired++
        } elseif ($expiry -lt $now.AddDays(30)) {
            $expiringSoon++
        }
    } catch { }
}
if ($expired -gt 0) {
    Add-Result -Level WARN -Check 'cert-expiry' -Message "$expired certificate(s) already expired"
}
if ($expiringSoon -gt 0) {
    Add-Result -Level WARN -Check 'cert-expiry' -Message "$expiringSoon certificate(s) expiring within 30 days"
}
if ($expired -eq 0 -and $expiringSoon -eq 0) {
    Add-Result -Level PASS -Check 'cert-expiry' -Message "No certificates expired or expiring within 30 days"
}

# ── Output ───────────────────────────────────────────────────────────────

$passCount = @($results | Where-Object { $_.Level -eq 'PASS' }).Count
$warnCount = @($results | Where-Object { $_.Level -eq 'WARN' }).Count
$failCount = @($results | Where-Object { $_.Level -eq 'FAIL' }).Count

if ($JsonOutput) {
    [PSCustomObject]@{
        file    = $Path
        pass    = $passCount
        warn    = $warnCount
        fail    = $failCount
        results = $results
    } | ConvertTo-Json -Depth 5
} else {
    $colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    foreach ($r in $results) {
        $prefix = $r.Level.PadRight(4)
        Write-Host "  $prefix  " -ForegroundColor $colors[$r.Level] -NoNewline
        Write-Host "[$($r.Check)] $($r.Message)"
    }
    Write-Host ""
    Write-Host "  Summary: " -NoNewline
    Write-Host "PASS: $passCount" -ForegroundColor Green -NoNewline
    Write-Host "  WARN: $warnCount" -ForegroundColor Yellow -NoNewline
    Write-Host "  FAIL: $failCount" -ForegroundColor Red
}

if ($failCount -gt 0) { exit 1 }
exit 0
