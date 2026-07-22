# Exercise 1 (Windows): SignedData with self-signed RSA cert.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new('certs\self-rsa.pfx', 'labpass', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

$bytes = [System.IO.File]::ReadAllBytes('inputs\hello.txt')
$contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)
$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
$signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner($cert)
$cms.ComputeSignature($signer)
[System.IO.File]::WriteAllBytes('outputs\01-signed-self.p7s', $cms.Encode())

$verify = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
$verify.Decode([System.IO.File]::ReadAllBytes('outputs\01-signed-self.p7s'))
try {
    $verify.CheckSignature($true)
    Write-Host 'PASS: Exercise 1 - SignedData (self-signed RSA, detached)'
} catch {
    Write-Host "FAIL: Exercise 1 verify failed: $_"
    exit 1
}
