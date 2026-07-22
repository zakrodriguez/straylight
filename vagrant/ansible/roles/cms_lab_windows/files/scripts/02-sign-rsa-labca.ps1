# Exercise 2 (Windows): SignedData with lab-CA RSA cert (WholeChain attached).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

# Get-Certificate-enrolled cert uses template's non-exportable key flag;
# load from LocalMachine\My by thumbprint instead of from a PFX.
$thumb = (Get-Content 'certs\rsa-labca.thumbprint' -Raw).Trim()
$cert = Get-Item "Cert:\LocalMachine\My\$thumb"

$bytes = [System.IO.File]::ReadAllBytes('inputs\hello.txt')
$contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)
$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
$signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner($cert)
$signer.IncludeOption = [System.Security.Cryptography.X509Certificates.X509IncludeOption]::WholeChain
$cms.ComputeSignature($signer)
[System.IO.File]::WriteAllBytes('outputs\02-signed-rsa-labca.p7s', $cms.Encode())

$verify = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
$verify.Decode([System.IO.File]::ReadAllBytes('outputs\02-signed-rsa-labca.p7s'))
try {
    $verify.CheckSignature($true)
    Write-Host 'PASS: Exercise 2 - SignedData (lab-CA RSA, chain attached)'
} catch {
    Write-Host "FAIL: Exercise 2 verify failed: $_"
    exit 1
}
