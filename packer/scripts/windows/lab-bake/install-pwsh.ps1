# Install PowerShell 7 from the host-staged cache CD (Packer lab-bake layer).
# See packer/scripts/windows/lab-bake/README.md for full rationale.
#
# Source: a small ISO Packer builds from `cd_files` in the HCL, attached as
# a secondary CD-ROM with label STRAYLIGHT_CACHE. The ISO contains the
# host-cached `vagrant/resources/software/PowerShell-{version}-win-x64.msi`
# (same MSI the Ansible runtime path uses via the synced folder).
# Native disk-speed read; no WinRM upload.

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

$msiPath = $null

Measure-Task 'locate-pwsh-msi' {
    $cacheVol = Get-Volume | Where-Object {
        $_.DriveType -eq 'CD-ROM' -and $_.FileSystemLabel -eq 'STRAYLIGHT_CACHE'
    } | Select-Object -First 1
    if (-not $cacheVol) {
        throw "STRAYLIGHT_CACHE CD not found. Volumes: $(Get-Volume | Out-String)"
    }
    $candidate = Get-ChildItem "$($cacheVol.DriveLetter):\PowerShell-*-win-x64.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $candidate) {
        throw "No PowerShell-*-win-x64.msi found on STRAYLIGHT_CACHE drive $($cacheVol.DriveLetter):"
    }
    $script:msiPath = $candidate.FullName
    Write-Host "Found $($script:msiPath) ($([Math]::Round($candidate.Length/1MB,1)) MB)"
}

if (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe') {
    $existing = & 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    Write-Host "PowerShell 7 already installed: $existing"
    return
}

Measure-Task 'install-pwsh-msi' {
    Write-Host "Installing PowerShell from $script:msiPath"
    $args = @(
        '/i', $script:msiPath, '/quiet', '/norestart',
        'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0',
        'ENABLE_PSREMOTING=0', 'REGISTER_MANIFEST=1',
        'USE_MU=0', 'ENABLE_MU=0'
    )
    $proc = Start-Process -FilePath msiexec.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "PowerShell MSI install failed (exit $($proc.ExitCode))" }
}

Measure-Task 'verify-pwsh-install' {
    $installed = & 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    Write-Host "PowerShell 7 installed: $installed"
}
