# Exercise 10 (Windows): Integrated end-to-end exercise.
# Dual-sign hello.txt (RSA labca + ECDSA self), envelope to 2 recipients,
# decrypt + verify round-trip.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

$thumb = (Get-Content 'certs\rsa-labca.thumbprint' -Raw).Trim()
$rsa = Get-Item "Cert:\LocalMachine\My\$thumb"
$ecdsa = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new('certs\self-ecdsa.pfx', 'labpass', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
$rsaSelf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new('certs\self-rsa.pfx', 'labpass', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

$bytes = [System.IO.File]::ReadAllBytes('inputs\hello.txt')
$contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)
$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
$cms.ComputeSignature((New-Object System.Security.Cryptography.Pkcs.CmsSigner($rsa)))
$cms.ComputeSignature((New-Object System.Security.Cryptography.Pkcs.CmsSigner($ecdsa)))
$dualSigned = $cms.Encode()
[System.IO.File]::WriteAllBytes('outputs\10b-signed-dual.p7s', $dualSigned)

$envCi = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$dualSigned)
$env = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms(
    $envCi,
    (New-Object System.Security.Cryptography.Pkcs.AlgorithmIdentifier(
        [System.Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.1.42'))))
# Two RSA recipients: rsaSelf and rsaLab. EnvelopedCms on Windows only supports
# KeyTrans (RSA) recipients; ECDH KeyAgree is unsupported — see canary 06.
$recip = New-Object System.Security.Cryptography.Pkcs.CmsRecipientCollection
$recip.Add((New-Object System.Security.Cryptography.Pkcs.CmsRecipient($rsaSelf))) | Out-Null
$recip.Add((New-Object System.Security.Cryptography.Pkcs.CmsRecipient($rsa))) | Out-Null
$env.Encrypt($recip)
[System.IO.File]::WriteAllBytes('outputs\10c-final.p7m', $env.Encode())

$decrypt = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
$decrypt.Decode([System.IO.File]::ReadAllBytes('outputs\10c-final.p7m'))
$store = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$store.Add($rsaSelf) | Out-Null
$decrypt.Decrypt($store)

$signedRecovered = $decrypt.ContentInfo.Content
$verify = New-Object System.Security.Cryptography.Pkcs.SignedCms(
    (New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)), $true)
$verify.Decode($signedRecovered)
try {
    $verify.CheckSignature($true)
    Write-Host 'PASS: Exercise 10 - Integrated (dual-sign -> envelope -> decrypt -> verify)'
} catch {
    Write-Host "FAIL: Exercise 10 verify failed: $_"
    exit 1
}
