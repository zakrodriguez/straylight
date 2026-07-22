# Exercise 3 (Windows): Pkcs.SignedCms with ML-DSA-65 lab-CA cert.
# Server 2025's .NET update added ML-DSA support to Pkcs.SignedCms — this
# exercise verifies the previously-documented gap has closed. If ComputeSignature
# starts failing again (regression), the walkthrough revives the workaround
# section that used openssl 3.5 via WSL.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

$thumb = (Get-Content 'certs\ml-dsa-labca.thumbprint' -Raw).Trim()
$cert = Get-Item "Cert:\LocalMachine\My\$thumb"

$bytes = [System.IO.File]::ReadAllBytes('inputs\hello.txt')
$contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)
$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
$signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner($cert)

try {
    $cms.ComputeSignature($signer)
    [System.IO.File]::WriteAllBytes('outputs\03-signed-ml-dsa.p7s', $cms.Encode())
    Write-Host 'PASS: Exercise 3 - SignedData (ML-DSA-65 via Pkcs.SignedCms, Server 2025 .NET)'
} catch {
    Write-Host "ALERT: Pkcs.SignedCms regressed on ML-DSA - reinstate openssl 3.5 workaround"
    Write-Host "  Error: $($_.Exception.Message)"
    exit 1
}
