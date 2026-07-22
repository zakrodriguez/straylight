<#
.SYNOPSIS
    Ingest CycloneDX CBOM components into OpenSearch as structured events.

.DESCRIPTION
    Transforms each CBOM component into a structured document and sends it to
    OpenSearch via the _bulk API. Each component becomes one index event with
    crypto-specific fields for dashboard queries.

.PARAMETER Path
    Path to CycloneDX CBOM JSON file.

.PARAMETER OpenSearchUrl
    OpenSearch base URL (default: https://192.168.56.53:9244 — TLS-terminating
    nginx data port on observe1, fronts the loopback-bound :9200). Requires
    -Credential (or -SkipCertCheck for the lab's step-ca-issued cert).

.PARAMETER Credential
    PSCredential for HTTP Basic Auth against the :9244 nginx front. Default
    is a hardcoded lab credential — override for non-lab use.

.PARAMETER SkipCertCheck
    Skip TLS certificate validation. Required when the host running this script
    doesn't trust the lab's step-ca root (e.g. ad-hoc runs from a workstation).

.PARAMETER Scanner
    Name of the scanner that produced this CBOM.

.PARAMETER EventType
    Event type label (default: 'scan'). Override for diff pipelines (e.g. 'diff-added', 'diff-removed').

.PARAMETER DryRun
    Print documents to stdout instead of sending to OpenSearch.

.PARAMETER JsonOutput
    Output all documents as a JSON array (implies DryRun).

.EXAMPLE
    .\CbomIngest.ps1 -Path cbom-deduped.json -Scanner cbomkit-theia
    .\CbomIngest.ps1 -Path cbom.json -Scanner cbom-lens -DryRun
    .\CbomIngest.ps1 -Path cbom.json -Scanner cbomkit-theia -EventType diff-added
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [string]$OpenSearchUrl = 'https://192.168.56.53:9244',

    [System.Management.Automation.PSCredential]$Credential = (
        [System.Management.Automation.PSCredential]::new(
            'beats',
            (ConvertTo-SecureString 'TenTowns00!' -AsPlainText -Force)
        )
    ),

    [switch]$SkipCertCheck,

    [string]$Scanner = 'unknown',

    [string]$EventType = 'scan',

    [switch]$DryRun,

    [switch]$JsonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Load CBOM ────────────────────────────────────────────────────────────

if (-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

$bom = Get-Content $Path -Raw | ConvertFrom-Json
$components = @($bom.components)
$scanTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# ── PQC classification ───────────────────────────────────────────────────

$quantumVulnerable = @('RSA', 'ECDSA', 'ECDH', 'DSA', 'DH', 'Ed25519', 'Ed448', 'X25519', 'X448')
$quantumSafe = @('AES', 'SHA-256', 'SHA-384', 'SHA-512', 'SHA3', 'ML-KEM', 'ML-DSA', 'SLH-DSA', 'XMSS', 'LMS')
$classicalWeak = @('MD5', 'SHA1', 'SHA-1', 'DES', '3DES', 'RC4', 'RC2')

function Get-PqcStatus {
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

# ── bom-ref index (for certificate PQC resolution) ───────────────────────

$refIndex = @{}
foreach ($c in $components) {
    $ref = $null; try { $ref = $c.'bom-ref' } catch { }
    if ($ref) { $refIndex[$ref] = $c }
}

function Get-CertPqcStatus {
    param($CertProps)
    $sigRef = $null; try { $sigRef = $CertProps.signatureAlgorithmRef } catch { }
    if ($sigRef -and $refIndex.ContainsKey($sigRef)) {
        $sigName = $null; try { $sigName = $refIndex[$sigRef].name } catch { }
        if ($sigName) { return Get-PqcStatus $sigName }
    }
    return 'unknown'
}

# ── Build documents ──────────────────────────────────────────────────────

$documents = [System.Collections.ArrayList]::new()

foreach ($c in $components) {
    $cp = $null; try { $cp = $c.cryptoProperties } catch { }
    $assetType = $null; try { $assetType = $cp.assetType } catch { }
    $name = $null; try { $name = $c.name } catch { }
    if (-not $name) { $name = '?' }

    # Extract location (first occurrence)
    $location = '?'
    try {
        $occ = $c.evidence.occurrences
        if ($occ -and $occ.Count -gt 0) {
            $loc = $null; try { $loc = $occ[0].location } catch { }
            if ($loc) { $location = $loc }
        }
    } catch { }

    # Extract VM name from location path (first path component)
    $vmName = '?'
    if ($location -ne '?' -and $location -match '^([^/]+)/') {
        $vmName = $Matches[1]
    }

    # Base document
    $doc = [ordered]@{
        '@timestamp'      = $scanTime
        'message'         = "[$Scanner] $assetType`: $name"
        cbom_scanner      = $Scanner
        cbom_scan_time    = $scanTime
        cbom_asset_type   = $assetType
        cbom_vm           = $vmName
        cbom_name         = $name
        cbom_location     = $location
        cbom_bom_ref      = $null
        cbom_event_type   = $EventType
    }
    try { $doc['cbom_bom_ref'] = $c.'bom-ref' } catch { }

    # Type-specific fields
    switch ($assetType) {
        'algorithm' {
            $ap = $null; try { $ap = $cp.algorithmProperties } catch { }
            $prim = $null; try { $prim = $ap.primitive } catch { }
            $doc['cbom_algorithm']  = $name
            $doc['cbom_primitive']  = $prim
            $doc['cbom_pqc_status'] = Get-PqcStatus $name
        }
        'certificate' {
            $certP = $null; try { $certP = $cp.certificateProperties } catch { }
            $subject   = $null; try { $subject   = $certP.subjectName    } catch { }
            $issuer    = $null; try { $issuer    = $certP.issuerName     } catch { }
            $notBefore = $null; try { $notBefore = $certP.notValidBefore } catch { }
            $notAfter  = $null; try { $notAfter  = $certP.notValidAfter  } catch { }
            $doc['cbom_subject']    = $subject
            $doc['cbom_issuer']     = $issuer
            $doc['cbom_not_before'] = $notBefore
            $doc['cbom_not_after']  = $notAfter

            # Resolve signature algorithm ref for PQC classification
            $doc['cbom_pqc_status'] = Get-CertPqcStatus $certP

            # Also store resolved signature algorithm name
            $sigRef = $null; try { $sigRef = $certP.signatureAlgorithmRef } catch { }
            if ($sigRef -and $refIndex.ContainsKey($sigRef)) {
                $sigAlg = $null; try { $sigAlg = $refIndex[$sigRef].name } catch { }
                if ($sigAlg) { $doc['cbom_sig_algorithm'] = $sigAlg }
            }

            # Days until certificate expiry (negative = already expired)
            if ($notAfter) {
                try {
                    $notAfterDt = [DateTimeOffset]::Parse($notAfter)
                    $delta = ($notAfterDt - [DateTimeOffset]::UtcNow)
                    $doc['cbom_days_to_expiry'] = $delta.Days
                } catch { }
            }

            # Self-signed detection
            if ($subject -and $issuer) {
                $doc['cbom_is_root'] = ($subject -eq $issuer)
            }
        }
        'related-crypto-material' {
            $rp    = $null; try { $rp    = $cp.relatedCryptoMaterialProperties } catch { }
            $kType = $null; try { $kType = $rp.type } catch { }
            $kSize = $null; try { $kSize = $rp.size } catch { }
            $doc['cbom_key_type']   = $kType
            $doc['cbom_key_size']   = $kSize
            $doc['cbom_pqc_status'] = Get-PqcStatus $name
        }
        default {
            $doc['cbom_pqc_status'] = Get-PqcStatus $name
        }
    }

    [void]$documents.Add($doc)
}

# ── Output / Send ────────────────────────────────────────────────────────

if ($JsonOutput) {
    $documents | ConvertTo-Json -Depth 5
    exit 0
}

if ($DryRun) {
    foreach ($doc in $documents) {
        $json = $doc | ConvertTo-Json -Depth 3 -Compress
        Write-Host $json
    }
    Write-Host ""
    Write-Host "  DryRun: $($documents.Count) documents generated (not sent)"
    exit 0
}

# Send to OpenSearch via _bulk API in batches of 500
$bulkUrl  = ($OpenSearchUrl.TrimEnd('/')) + '/cbom/_bulk'
$batchSize = 500
$sent     = 0
$errors   = 0

for ($i = 0; $i -lt $documents.Count; $i += $batchSize) {
    $batch = $documents[$i..[Math]::Min($i + $batchSize - 1, $documents.Count - 1)]
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($doc in $batch) {
        $lines.Add('{"index":{}}')
        $lines.Add(($doc | ConvertTo-Json -Depth 3 -Compress))
    }
    # NDJSON requires trailing newline
    $body = ($lines -join "`n") + "`n"

    try {
        $irmArgs = @{
            Uri         = $bulkUrl
            Method      = 'Post'
            Body        = $body
            ContentType = 'application/x-ndjson'
            Credential  = $Credential
        }
        if ($SkipCertCheck) { $irmArgs['SkipCertificateCheck'] = $true }
        $response = Invoke-RestMethod @irmArgs
        $batchErrors = 0
        if ($response.errors) {
            foreach ($item in $response.items) {
                if ($item.index.PSObject.Properties['error']) {
                    $batchErrors++
                    if (($errors + $batchErrors) -le 3) {
                        Write-Warning "Bulk error: $($item.index.error)"
                    }
                }
            }
        }
        $sent   += $batch.Count - $batchErrors
        $errors += $batchErrors
    } catch {
        $errors += $batch.Count
        if ($errors -le 3) {
            Write-Warning "Failed to send batch: $_"
        }
    }
}

Write-Host "  Sent: $sent / $($documents.Count) documents to $bulkUrl" -ForegroundColor Green
if ($errors -gt 0) {
    Write-Host "  Errors: $errors" -ForegroundColor Red
}

if ($errors -gt 0) { exit 1 }
exit 0
