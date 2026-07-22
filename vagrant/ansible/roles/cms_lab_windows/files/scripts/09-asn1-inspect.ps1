# Exercise 9 (Windows): ASN.1 inspection of CMS artifacts.
# System.Formats.Asn1.AsnReader is only in .NET 5+; PS5/Server 2025 default
# shell is .NET Framework 4.x, so we use AsnEncodedData.Format() instead.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

$artifacts = @(
    'outputs\02-signed-rsa-labca.p7s',
    'outputs\05-enveloped-rsa.p7m'
)

foreach ($art in $artifacts) {
    if (-not (Test-Path $art)) {
        Write-Host "SKIP: $art (run prerequisite exercise first)"
        continue
    }
    Write-Host "--- $art ---"
    $bytes = [System.IO.File]::ReadAllBytes($art)
    # AsnEncodedData with the SEQUENCE OID gives a human-readable hex dump.
    $asn = New-Object System.Security.Cryptography.AsnEncodedData(,$bytes)
    $formatted = $asn.Format($true)
    Set-Content -Path "$art.annotated.txt" -Value $formatted -Encoding ASCII
    # Show first 6 lines so the operator sees the SEQUENCE / OID header.
    ($formatted -split "`n" | Select-Object -First 6) -join "`n" | Write-Host
    Write-Host "  wrote $art.annotated.txt ($(($formatted -split "`n").Count) lines)"
}

Write-Host 'PASS: Exercise 9 - ASN.1 inspection (AsnEncodedData.Format)'
