# Exercise 5 (Windows): EnvelopedData with RSA-OAEP recipients (2).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

$rsaSelf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new('certs\self-rsa.pfx', 'labpass', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
$thumb = (Get-Content 'certs\rsa-labca.thumbprint' -Raw).Trim()
$rsaLab = Get-Item "Cert:\LocalMachine\My\$thumb"

$bytes = [System.IO.File]::ReadAllBytes('inputs\hello.txt')
$contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)
$envelope = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms(
    $contentInfo,
    (New-Object System.Security.Cryptography.Pkcs.AlgorithmIdentifier(
        [System.Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.1.42'))))

$recipients = New-Object System.Security.Cryptography.Pkcs.CmsRecipientCollection
$recipients.Add((New-Object System.Security.Cryptography.Pkcs.CmsRecipient($rsaSelf))) | Out-Null
$recipients.Add((New-Object System.Security.Cryptography.Pkcs.CmsRecipient($rsaLab))) | Out-Null

$envelope.Encrypt($recipients)
[System.IO.File]::WriteAllBytes('outputs\05-enveloped-rsa.p7m', $envelope.Encode())

$decrypt = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
$decrypt.Decode([System.IO.File]::ReadAllBytes('outputs\05-enveloped-rsa.p7m'))
$store = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$store.Add($rsaSelf) | Out-Null
$decrypt.Decrypt($store)

if ([System.Text.Encoding]::UTF8.GetString($decrypt.ContentInfo.Content) -eq
    [System.Text.Encoding]::UTF8.GetString($bytes)) {
    Write-Host 'PASS: Exercise 5 - EnvelopedData (RSA-OAEP, 2 recipients)'
} else {
    Write-Host 'FAIL: Exercise 5 decrypt mismatch'
    exit 1
}
