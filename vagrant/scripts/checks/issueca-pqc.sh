#!/bin/bash
# scripts/checks/issueca-pqc.sh — extracted from validate.sh verbatim.
register_checks_issueca_pqc() {
# ─── ISSUECA-PQC (pqc-adcs-two-tier only) ───────────────────────────────
# Enterprise ML-DSA-65 issuing CA. Verify CertSvc, the PQC leaf template is
# published, and an ML-DSA-65 leaf (NIST id-ml-dsa-65 = 2.16.840.1.101.3.4.3.18)
# was issued on the CA itself and chains to the PQC root.

if ! profile_has issueca-pqc; then
    skip_vm issueca-pqc "not in profile '$LAB_PROFILE_NAME'"
elif is_running issueca-pqc; then
        launch_check issueca-pqc run_windows_check issueca-pqc "$(cat <<'PS1'
try { Get-Service CertSvc -ErrorAction Stop | Out-Null; Write-Output "PASS: CertSvc (AD CS) running" }
catch { Write-Output "FAIL: CertSvc (AD CS) not running" }

# ── PQC leaf template published (certutil -catemplates via SYSTEM schtask) ──
$tplScript = @'
$output = certutil -catemplates 2>&1 | Out-String
if ($output -match [regex]::Escape('Straylight-PQC-Machine-MLDSA65-v1')) {
    "PASS: Template 'Straylight-PQC-Machine-MLDSA65-v1' published" | Out-File C:\validate-pqc-tpl.txt -Encoding ASCII
} else {
    "FAIL: Template 'Straylight-PQC-Machine-MLDSA65-v1' NOT published" | Out-File C:\validate-pqc-tpl.txt -Encoding ASCII
}
'@
$tplScript | Out-File C:\validate-pqc-tpl.ps1 -Encoding ASCII
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -File C:\validate-pqc-tpl.ps1'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'ValidatePQCTemplate' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'ValidatePQCTemplate'
$timeout = 20; $elapsed = 0
while ($elapsed -lt $timeout) {
    Start-Sleep 3; $elapsed += 3
    if ((Get-ScheduledTask -TaskName 'ValidatePQCTemplate').State -eq 'Ready') { break }
}
Get-Content C:\validate-pqc-tpl.txt -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
Unregister-ScheduledTask -TaskName 'ValidatePQCTemplate' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item C:\validate-pqc-tpl.ps1, C:\validate-pqc-tpl.txt -Force -ErrorAction SilentlyContinue

# ── ML-DSA-65 leaf issued + chains to PQC root ──
$serverAuthOid = '1.3.6.1.5.5.7.3.1'
$mldsa65Oid = '2.16.840.1.101.3.4.3.18'
$leaf = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object {
        $_.EnhancedKeyUsageList.ObjectId -contains $serverAuthOid -and
        $_.PublicKey.Oid.Value -eq $mldsa65Oid -and
        $_.NotAfter -gt (Get-Date)
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
if ($leaf) {
    # AD-bound leaf has an empty Subject (identity lives in the SAN), so report
    # the DNS SAN — falling back to Subject, then a short thumbprint.
    $san = ($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($false) }) -join '; '
    $leafId = if ($san) { $san } elseif ($leaf.Subject) { $leaf.Subject } else { "thumbprint $($leaf.Thumbprint.Substring(0,12))" }
    Write-Output "PASS: ML-DSA-65 leaf issued ($leafId)"
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    if ($chain.Build($leaf)) {
        Write-Output "PASS: ML-DSA-65 leaf chain validates to PQC root"
    } else {
        $statuses = ($chain.ChainStatus | ForEach-Object { $_.Status }) -join ','
        Write-Output "FAIL: ML-DSA-65 leaf chain did not validate ($statuses)"
    }
} else {
    Write-Output "FAIL: No ML-DSA-65 Server-Auth leaf in LocalMachine\My"
}
PS1
)
$(ps_check_winlogbeat)
$(ps_check_sysmon)
$(ps_check_psframework)
$(ps_check_adcs_audit)" "$TMPDIR_VAL/issueca-pqc"
else
        skip_vm issueca-pqc
fi
}
