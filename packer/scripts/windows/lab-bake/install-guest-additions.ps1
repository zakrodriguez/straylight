# Install VirtualBox Guest Additions silently (Packer lab-bake layer).
# See packer/scripts/windows/lab-bake/README.md for full rationale.
#
# Source: the GA ISO attached as a CD-ROM via HCL `guest_additions_mode =
# "attach"`. We read VBoxWindowsAdditions.exe directly off the CD rather
# than uploading the ISO over WinRM + Mount-DiskImage (saves ~60 MB of
# slow chunked WinRM transfer + the mount-volume drive-letter dance).

$ErrorActionPreference = 'Stop'

$script:ScriptName = (Get-Item $PSCommandPath).Name
function Measure-Task {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    Write-Host ("[TASK-START] script={0} task={1} ts={2}" -f $script:ScriptName, $Name, (Get-Date).ToUniversalTime().ToString('o'))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $ScriptBlock
        $sw.Stop()
        Write-Host ("[TASK-END]   script={0} task={1} status=ok elapsed_ms={2}" -f $script:ScriptName, $Name, $sw.ElapsedMilliseconds)
    } catch {
        $sw.Stop()
        Write-Host ("[TASK-END]   script={0} task={1} status=fail elapsed_ms={2} error={3}" -f $script:ScriptName, $Name, $sw.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
}

# Skip if already installed (cheap idempotency check)
$svc = Get-Service VBoxService -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host "VBoxService already running -- GA appears installed, skipping"
    return
}

$driveRoot = $null
Measure-Task 'locate-ga-cd' {
    # VBox attaches the GA ISO with a label like "VBox_GAs_<version>".
    # Find the CD by either label OR by looking for VBoxWindowsAdditions.exe.
    $volumes = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter }
    foreach ($v in $volumes) {
        $candidate = "$($v.DriveLetter):\VBoxWindowsAdditions.exe"
        if (Test-Path $candidate) {
            $script:driveRoot = "$($v.DriveLetter):"
            Write-Host "GA CD found at $script:driveRoot (label=$($v.FileSystemLabel))"
            return
        }
    }
    throw "VBoxWindowsAdditions.exe not found on any attached CD-ROM. Volumes seen: $($volumes | Out-String)"
}

Measure-Task 'trust-oracle-certs' {
    $certDir = Join-Path $script:driveRoot 'cert'
    if (Test-Path $certDir) {
        $certs = Get-ChildItem (Join-Path $certDir '*.cer') -ErrorAction SilentlyContinue
        foreach ($cert in $certs) {
            Write-Host "Trusting cert: $($cert.Name)"
            $out = & certutil.exe -addstore -f 'TrustedPublisher' $cert.FullName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "certutil -addstore failed for $($cert.Name): $out"
            }
        }
    } else {
        Write-Warning "No cert/ directory on GA CD -- install may prompt for driver trust"
    }
}

Measure-Task 'install-vboxadditions' {
    $installer = Join-Path $script:driveRoot 'VBoxWindowsAdditions.exe'
    Write-Host "Running $installer /S (silent install)"
    $proc = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru -NoNewWindow
    $exit = $proc.ExitCode
    Write-Host "VBoxWindowsAdditions exit code: $exit"
    # 3010 = "reboot required" (normal); 0 = success without reboot
    if ($exit -ne 0 -and $exit -ne 3010) {
        throw "VBoxWindowsAdditions installer failed (exit $exit)"
    }
}

Write-Host "GA install complete. Reboot pending (handled by next provisioner)."
