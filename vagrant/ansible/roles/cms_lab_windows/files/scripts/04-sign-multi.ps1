# Exercise 4 (Windows): SignedData with dual signer (RSA labca + ECDSA self).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

$thumb = (Get-Content 'certs\rsa-labca.thumbprint' -Raw).Trim()
$rsa = Get-Item "Cert:\LocalMachine\My\$thumb"
$ecdsa = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new('certs\self-ecdsa.pfx', 'labpass', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

$bytes = [System.IO.File]::ReadAllBytes('inputs\hello.txt')
$contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)
$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)

$cms.ComputeSignature((New-Object System.Security.Cryptography.Pkcs.CmsSigner($rsa)))
$cms.ComputeSignature((New-Object System.Security.Cryptography.Pkcs.CmsSigner($ecdsa)))

[System.IO.File]::WriteAllBytes('outputs\04-signed-multi.p7s', $cms.Encode())

$verify = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
$verify.Decode([System.IO.File]::ReadAllBytes('outputs\04-signed-multi.p7s'))
try {
    $verify.CheckSignature($true)
    Write-Host 'PASS: Exercise 4 - SignedData (dual signer: RSA labca + ECDSA self)'
} catch {
    Write-Host "FAIL: Exercise 4 verify failed: $_"
    exit 1
}
