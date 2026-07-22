# Exercise 8 canary (Windows): try EnvelopedCms with AES-GCM AlgorithmIdentifier.
# EXPECTED to fail. .NET high-level Pkcs API doesn't expose AuthEnvelopedData.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null

try {
    $aesGcmOid = [System.Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.1.46')  # AES-256-GCM
    $alg = New-Object System.Security.Cryptography.Pkcs.AlgorithmIdentifier($aesGcmOid)
    $envelope = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms(
        (New-Object System.Security.Cryptography.Pkcs.ContentInfo([byte[]]@(1,2,3))),
        $alg)
    # Need at least one recipient to actually try encrypt; use self-rsa if available.
    $selfRsaPath = 'C:\cms-lab\certs\self-rsa.pfx'
    if (Test-Path $selfRsaPath) {
        $cert = Get-PfxCertificate -FilePath $selfRsaPath `
            -Password (ConvertTo-SecureString 'labpass' -Force -AsPlainText)
        $recipients = New-Object System.Security.Cryptography.Pkcs.CmsRecipientCollection
        $recipients.Add((New-Object System.Security.Cryptography.Pkcs.CmsRecipient($cert))) | Out-Null
        $envelope.Encrypt($recipients)
    } else {
        $envelope.Encrypt((New-Object System.Security.Cryptography.Pkcs.CmsRecipientCollection))
    }
    Write-Host 'ALERT: EnvelopedCms now supports AES-GCM (AuthEnvelopedData) - revisit walkthrough'
    exit 1
} catch {
    Write-Host 'PASS: EnvelopedCms AES-GCM/AuthEnvelopedData gap still present'
    Write-Host "  Error: $($_.Exception.Message)"
}
