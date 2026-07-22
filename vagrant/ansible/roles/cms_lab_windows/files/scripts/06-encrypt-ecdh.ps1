# Exercise 6 canary (Windows): try EnvelopedCms with an ECDH-ES recipient.
# Windows .NET high-level Pkcs.EnvelopedCms only supports KeyTrans recipients
# (RSA-OAEP, RSA-PKCS-v1.5). ECDH KeyAgree recipients return NTSTATUS
# 0xC00000BB (STATUS_NOT_SUPPORTED). Linux/openssl does this fine — see
# scanner1 Exercise 6. Lab walkthrough discusses the parity gap.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null
Set-Location C:\cms-lab

$ecdsa = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new('certs\self-ecdsa.pfx', 'labpass', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

$bytes = [System.IO.File]::ReadAllBytes('inputs\hello.txt')
$contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(,$bytes)
$envelope = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms(
    $contentInfo,
    (New-Object System.Security.Cryptography.Pkcs.AlgorithmIdentifier(
        [System.Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.1.42'))))

$recipients = New-Object System.Security.Cryptography.Pkcs.CmsRecipientCollection
$recipients.Add((New-Object System.Security.Cryptography.Pkcs.CmsRecipient($ecdsa))) | Out-Null

try {
    $envelope.Encrypt($recipients)
    Write-Host 'ALERT: EnvelopedCms now accepts ECDH-ES KeyAgree - Exercise 6 walkthrough needs revision'
    [System.IO.File]::WriteAllBytes('outputs\06-enveloped-ecdh.p7m', $envelope.Encode())
    exit 1
} catch {
    Write-Host 'PASS: EnvelopedCms ECDH-ES KeyAgree gap still present (parity gap with openssl)'
    Write-Host "  Error: $($_.Exception.Message)"
}
