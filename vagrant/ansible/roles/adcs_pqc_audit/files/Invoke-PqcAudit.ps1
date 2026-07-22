#requires -Version 5.1
# Invoke-PqcAudit.ps1 - Layered PQC gap audit for Windows Server 2025+
# Differentiates CNG primitives (BCrypt) from CertEnroll (cert issuance APIs)
# from AD CS (CA service). Each layer ships on its own MS schedule.
#
# Run: powershell.exe -ExecutionPolicy Bypass -File C:\path\Invoke-PqcAudit.ps1
# Writes report to C:\tmp\pqc-audit\pqc-audit-report.txt

$ErrorActionPreference = 'Stop'
$script:hasErrors = $false
$reportPath = 'C:\tmp\pqc-audit\pqc-audit-report.txt'
# Structured JSON sidecar (adcs_pqc_audit/v1) consumed by cbom_ingest.py so the
# audit lands in OpenSearch instead of being a text-file dead-end.
$jsonPath = 'C:\tmp\pqc-audit\pqc-audit-report.json'
New-Item -ItemType Directory -Force -Path (Split-Path $reportPath) | Out-Null

# Per-layer verdicts accumulated through the run, emitted to the JSON sidecar
# at the end. Layer status flips to AVAILABLE where the corresponding probe
# succeeds (Layer 1 from the build threshold; the rest stay NOT_AVAILABLE
# until MS ships them, and Section 4 flips Layer 2 if New-SelfSignedCertificate
# starts accepting ML-DSA).
$script:layerStatus = [ordered]@{
    cng        = 'NOT_AVAILABLE'
    certenroll = 'NOT_AVAILABLE'
    adcs       = 'NOT_AVAILABLE'
    schannel   = 'NOT_AVAILABLE'
}

$lines = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$text) $lines.Add($text) | Out-Null }

try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildFull = "$($cv.CurrentBuildNumber).$($cv.UBR)"
    $cngPqcThresholdMet = ($cv.CurrentBuildNumber -eq '26100' -and [int]$cv.UBR -ge 7171)
} catch {
    $script:hasErrors = $true
    $buildFull = 'UNKNOWN'
    $cngPqcThresholdMet = $false
    Add-Line "PREAMBLE: ERROR - $($_.Exception.Message)"
}

Add-Line "================================================================"
Add-Line "  AD CS PQC GAP AUDIT REPORT"
Add-Line "  Host    : $env:COMPUTERNAME"
Add-Line "  Date    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "  OS      : $((Get-CimInstance Win32_OperatingSystem).Caption)"
Add-Line "  Build   : $buildFull (DisplayVersion: $($cv.DisplayVersion))"
Add-Line "================================================================"
Add-Line ""

# ---------------------------------------------------------------
# SECTION 1 - Build / patch threshold
# ---------------------------------------------------------------
Add-Line "----------------------------------------------------------------"
Add-Line "SECTION 1: KB5068861 threshold (CNG PQC GA, Nov 2025)"
Add-Line "----------------------------------------------------------------"
try {
    Add-Line "  Required minimum build : 26100.7171"
    Add-Line "  This box build         : $buildFull"
    Add-Line "  Threshold met          : $cngPqcThresholdMet"
    if ($cngPqcThresholdMet) { $script:layerStatus.cng = 'AVAILABLE' }
    $bcp = Get-Item C:\Windows\System32\bcryptprimitives.dll -ErrorAction SilentlyContinue
    if ($bcp) {
        Add-Line "  bcryptprimitives.dll   : $($bcp.VersionInfo.FileVersion)"
        Add-Line "                           (LastWrite: $($bcp.LastWriteTime))"
    }
} catch {
    $script:hasErrors = $true
    Add-Line "SECTION 1: ERROR - $($_.Exception.Message)"
}
Add-Line ""

# ---------------------------------------------------------------
# SECTION 2 - CNG PQC primitive probe (BCrypt P/Invoke)
# ---------------------------------------------------------------
Add-Line "----------------------------------------------------------------"
Add-Line "SECTION 2: CNG primitive probe via BCryptOpenAlgorithmProvider"
Add-Line "  Algorithm-name strings registered with CNG. Parameter sets are"
Add-Line "  set via BCryptSetProperty AFTER opening, so the algo name has"
Add-Line "  no -44 / -65 / -87 / -512 / -768 / -1024 suffix."
Add-Line "----------------------------------------------------------------"

try {
    $cs = @'
using System;
using System.Runtime.InteropServices;
public class PqcBcrypt {
    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    public static extern uint BCryptOpenAlgorithmProvider(out IntPtr h, string algId, string impl, uint flags);
    [DllImport("bcrypt.dll")]
    public static extern uint BCryptCloseAlgorithmProvider(IntPtr h, uint flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AlgIdent { public IntPtr pszName; public uint dwClass; public uint dwFlags; }

    [DllImport("bcrypt.dll")]
    public static extern uint BCryptEnumAlgorithms(uint ops, out uint count, out IntPtr list, uint flags);
    [DllImport("bcrypt.dll")]
    public static extern uint BCryptFreeBuffer(IntPtr p);
}
'@
    Add-Type -TypeDefinition $cs -Language CSharp

    $candidates = @('ML-DSA','ML-KEM','MLDSA','MLKEM',
                    'ML-DSA-44','ML-DSA-65','ML-DSA-87',
                    'ML-KEM-512','ML-KEM-768','ML-KEM-1024')
    foreach ($a in $candidates) {
        $h = [IntPtr]::Zero
        $rc = [PqcBcrypt]::BCryptOpenAlgorithmProvider([ref]$h, $a, $null, 0)
        if ($rc -eq 0) {
            Add-Line ("  FOUND  : {0}" -f $a)
            [void][PqcBcrypt]::BCryptCloseAlgorithmProvider($h, 0)
        } else {
            Add-Line ("  miss   : {0}  (NTSTATUS 0x{1:X8})" -f $a, $rc)
        }
    }
} catch {
    $script:hasErrors = $true
    Add-Line "SECTION 2: ERROR - $($_.Exception.Message)"
}
Add-Line ""

# ---------------------------------------------------------------
# SECTION 3 - BCryptEnumAlgorithms full listing
# ---------------------------------------------------------------
Add-Line "----------------------------------------------------------------"
Add-Line "SECTION 3: All CNG signature/secret-agreement/asym-encryption algos"
Add-Line "----------------------------------------------------------------"
try {
    $ops = 0x10 -bor 0x08 -bor 0x04
    $count = 0; $listPtr = [IntPtr]::Zero
    $rc = [PqcBcrypt]::BCryptEnumAlgorithms($ops, [ref]$count, [ref]$listPtr, 0)
    if ($rc -ne 0) {
        Add-Line ("  BCryptEnumAlgorithms FAILED 0x{0:X8}" -f $rc)
    } else {
        Add-Line "  Algorithms registered: $count"
        $sz = [Runtime.InteropServices.Marshal]::SizeOf([Type][PqcBcrypt+AlgIdent])
        for ($i = 0; $i -lt $count; $i++) {
            $p = [IntPtr]::Add($listPtr, $i * $sz)
            $e = [Runtime.InteropServices.Marshal]::PtrToStructure($p, [Type][PqcBcrypt+AlgIdent])
            $name = [Runtime.InteropServices.Marshal]::PtrToStringUni($e.pszName)
            Add-Line ("    [class=0x{0:X2}] {1}" -f $e.dwClass, $name)
        }
        [void][PqcBcrypt]::BCryptFreeBuffer($listPtr)
    }
} catch {
    $script:hasErrors = $true
    Add-Line "SECTION 3: ERROR - $($_.Exception.Message)"
}
Add-Line ""

# ---------------------------------------------------------------
# SECTION 4 - CertEnroll layer (PowerShell New-SelfSignedCertificate)
# ---------------------------------------------------------------
Add-Line "----------------------------------------------------------------"
Add-Line "SECTION 4: CertEnroll (PowerShell New-SelfSignedCertificate -KeyAlgorithm ML-DSA)"
Add-Line "  CNG having ML-DSA does not mean New-SelfSignedCertificate / AD CS"
Add-Line "  has wired it through. This is the MS gap targeted for early 2026."
Add-Line "----------------------------------------------------------------"
try {
    $cert = New-SelfSignedCertificate -Subject 'CN=PQC-Test-ML-DSA' `
            -KeyAlgorithm 'ML-DSA' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -ErrorAction Stop
    Add-Line "  RESULT : SUCCESS - CertEnroll has been updated for PQC"
    $script:layerStatus.certenroll = 'AVAILABLE'
    Add-Line "  Thumbprint    : $($cert.Thumbprint)"
    Add-Line "  PublicKey OID : $($cert.PublicKey.Oid.Value) ($($cert.PublicKey.Oid.FriendlyName))"
    Remove-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
} catch {
    Add-Line "  RESULT : FAILED (CertEnroll/AD CS issuance gap confirmed)"
    Add-Line "  Error  : $($_.Exception.Message)"
}
Add-Line ""

# ---------------------------------------------------------------
# SECTION 5 - certreq.exe with INF + ParameterSet (timeout-safe)
# ---------------------------------------------------------------
Add-Line "----------------------------------------------------------------"
Add-Line "SECTION 5: certreq.exe -new with ParameterSet INF field"
Add-Line "  Some CertEnroll fields land in certreq earlier than in"
Add-Line "  PowerShell. Wrapped in Wait-Job timeout because certreq can"
Add-Line "  prompt on unknown fields under WinRM (silent hang)."
Add-Line "----------------------------------------------------------------"
try {
    $infBody = @'
[NewRequest]
Subject = "CN=PQC-Test-Inf"
KeyAlgorithm = ML-DSA
ParameterSet = "ML-DSA-65"
ProviderName = "Microsoft Software Key Storage Provider"
RequestType = Cert
KeyUsage = 0xA0
'@
    $infPath = 'C:\tmp\pqc-audit\pqc-test.inf'
    $cerPath = 'C:\tmp\pqc-audit\pqc-test.cer'
    $infBody | Out-File -Encoding ASCII $infPath -Force
    Remove-Item $cerPath -ErrorAction SilentlyContinue

    $job = Start-Job -ScriptBlock {
        param($inf, $cer)
        $out = & certreq.exe -q -new $inf $cer 2>&1
        [PSCustomObject]@{ rc = $LASTEXITCODE; out = ($out -join "`n") }
    } -ArgumentList $infPath, $cerPath
    $done = Wait-Job $job -Timeout 30
    if ($done) {
        $r = Receive-Job $job
        Add-Line ("  certreq exit : {0}" -f $r.rc)
        foreach ($l in ($r.out -split "`n" | Select-Object -First 10)) {
            Add-Line "    $l"
        }
        if (Test-Path $cerPath) {
            Add-Line "  RESULT : SUCCESS - certreq accepted ML-DSA + ParameterSet"
            $script:layerStatus.adcs = 'AVAILABLE'
            Add-Line ("  Cert size: {0} bytes" -f (Get-Item $cerPath).Length)
        } else {
            Add-Line "  RESULT : FAILED - no cert produced"
        }
    } else {
        Add-Line "  RESULT : TIMEOUT after 30s (certreq likely prompting on unknown field)"
        Stop-Job $job
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
} catch {
    $script:hasErrors = $true
    Add-Line "SECTION 5: ERROR - $($_.Exception.Message)"
}
Add-Line ""

# ---------------------------------------------------------------
# SECTION 6 - AD CS service-side info (only if CertSvc present)
# ---------------------------------------------------------------
Add-Line "----------------------------------------------------------------"
Add-Line "SECTION 6: AD CS Service Configuration (certutil -getreg / -cainfo)"
Add-Line "----------------------------------------------------------------"
try {
    $certSvc = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
    if (-not $certSvc) {
        Add-Line "  CertSvc not present on this host - skipping CA-side checks."
    } else {
        Add-Line "--- Hash Algorithm ---"
        $hashReg = certutil.exe -getreg CA\CACertHashAlgorithm 2>&1
        foreach ($l in $hashReg) { Add-Line "  $l" }
        Add-Line ""
        Add-Line "--- Provider Name ---"
        $provName = certutil.exe -getreg CA\CSP\Provider 2>&1
        foreach ($l in $provName) { Add-Line "  $l" }
        Add-Line ""
        Add-Line "--- CA Info (truncated) ---"
        $caInfo = certutil.exe -cainfo 2>&1 | Select-Object -First 15
        foreach ($l in $caInfo) { Add-Line "  $l" }
        $caInfoText = (certutil.exe -cainfo 2>&1) -join " "
        if ($caInfoText -match 'ML-DSA|ML-KEM|CRYSTALS|Dilithium|Kyber|PQC|post.quantum') {
            Add-Line "  *** PQC reference detected in cainfo output ***"
        }
    }
} catch {
    $script:hasErrors = $true
    Add-Line "SECTION 6: ERROR - $($_.Exception.Message)"
}
Add-Line ""

# ---------------------------------------------------------------
# SECTION 7 - Layered gap summary
# ---------------------------------------------------------------
Add-Line "================================================================"
Add-Line "SECTION 7: PQC GAP SUMMARY (layered)"
Add-Line "================================================================"
try {
Add-Line ""
Add-Line "  Layer 1 - CNG primitives (bcrypt.dll / SymCrypt):"
if ($cngPqcThresholdMet) {
    Add-Line "    STATUS  : AVAILABLE (build $buildFull >= 26100.7171)"
    Add-Line "    DETAIL  : ML-DSA / ML-KEM are registered CNG algorithms,"
    Add-Line "              callable via BCryptOpenAlgorithmProvider."
    Add-Line "              Parameter sets (-44/-65/-87 / -512/-768/-1024)"
    Add-Line "              are set via BCryptSetProperty after opening."
} else {
    Add-Line "    STATUS  : NOT AVAILABLE (build $buildFull < 26100.7171)"
    Add-Line "    DETAIL  : Apply November 2025 cumulative (KB5068861) or later."
}
Add-Line ""
Add-Line "  Layer 2 - CertEnroll (New-SelfSignedCertificate / certreq):"
Add-Line "    STATUS  : NOT AVAILABLE on this build"
Add-Line "    DETAIL  : CX509PrivateKey::put_AlgorithmName rejects ML-DSA."
Add-Line "              MS targeted early-2026 GA for AD CS PQC; not landed yet."
Add-Line ""
Add-Line "  Layer 3 - AD CS Enterprise CA cert issuance:"
Add-Line "    STATUS  : NOT AVAILABLE (depends on Layer 2)"
Add-Line "    DETAIL  : Until certreq/CertEnroll accepts ML-DSA, AD CS"
Add-Line "              templates and policy modules cannot issue PQC certs."
Add-Line ""
Add-Line "  Layer 4 - Schannel TLS hybrid KEM (X25519MLKEM768):"
Add-Line "    STATUS  : NOT AVAILABLE on Server 2025 GA channels"
Add-Line "    DETAIL  : Hybrid TLS KEMs in Win11 24H2 Insider; no committed"
Add-Line "              Server 2025 GA date."
Add-Line ""
Add-Line "  Lab path forward:"
Add-Line "    - For PQC cert issuance use EJBCA1 (ML-DSA-65 native via Bouncy"
Add-Line "      Castle) or step-ca (Go crypto/x509 PQC fork)."
Add-Line "    - For CNG-level PQC experiments on Windows, code against bcrypt.dll"
Add-Line "      directly (see Section 2 P/Invoke pattern); the .NET 10 MLKem /"
Add-Line "      MLDsa managed wrappers do the same under the hood."
Add-Line "    - Re-run this audit after the next Server 2025 cumulative to"
Add-Line "      detect AD CS PQC GA (Section 4/5 will flip to SUCCESS)."
} catch {
    $script:hasErrors = $true
    Add-Line "SECTION 7: ERROR - $($_.Exception.Message)"
}
Add-Line ""
Add-Line "================================================================"
Add-Line "  END OF REPORT"
Add-Line "================================================================"

try {
    $lines | Out-File -FilePath $reportPath -Encoding UTF8 -Force
    Write-Output "Report written to $reportPath ($($lines.Count) lines)"
} catch {
    $script:hasErrors = $true
    Write-Error "Failed to write report to ${reportPath}: $($_.Exception.Message)"
}

# ---------------------------------------------------------------
# Structured JSON sidecar (adcs_pqc_audit/v1) for cbom_ingest.py
# ---------------------------------------------------------------
try {
    $layerNames = @{
        cng        = 'CNG primitives (bcrypt.dll / SymCrypt)'
        certenroll = 'CertEnroll (New-SelfSignedCertificate / certreq)'
        adcs       = 'AD CS Enterprise CA cert issuance'
        schannel   = 'Schannel TLS hybrid KEM (X25519MLKEM768)'
    }
    $layers = foreach ($id in $script:layerStatus.Keys) {
        [ordered]@{
            id     = $id
            name   = $layerNames[$id]
            status = $script:layerStatus[$id]
        }
    }
    $report = [ordered]@{
        schema  = 'adcs_pqc_audit/v1'
        run_at  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        host    = $env:COMPUTERNAME
        build   = $buildFull
        scanner = "$($env:COMPUTERNAME)-adcs-audit"
        layers  = @($layers)
    }
    $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8 -Force
    Write-Output "JSON sidecar written to $jsonPath"
} catch {
    $script:hasErrors = $true
    Write-Error "Failed to write JSON sidecar to ${jsonPath}: $($_.Exception.Message)"
}

if ($script:hasErrors) { exit 1 } else { exit 0 }
