# Exercise 7 canary (Windows): try EnvelopedCms with ML-KEM AlgorithmIdentifier.
# EXPECTED to fail. .NET high-level Pkcs API doesn't have KEMRecipientInfo support.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security | Out-Null

try {
    $kemOid = [System.Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.4.2')  # ML-KEM-768
    $alg = New-Object System.Security.Cryptography.Pkcs.AlgorithmIdentifier($kemOid)
    $envelope = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms(
        (New-Object System.Security.Cryptography.Pkcs.ContentInfo([byte[]]@(1,2,3))),
        $alg)
    $envelope.Encrypt((New-Object System.Security.Cryptography.Pkcs.CmsRecipientCollection))
    Write-Host 'ALERT: EnvelopedCms now accepts ML-KEM - Exercise 7 walkthrough needs revision'
    exit 1
} catch {
    Write-Host 'PASS: EnvelopedCms ML-KEM gap still present (workaround section stays valid)'
    Write-Host "  Error: $($_.Exception.Message)"
}
