# Pre-install ADCS Windows features (Packer lab-bake layer).
# See packer/scripts/windows/lab-bake/README.md for full rationale.

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

$features = @(
    'ADCS-Cert-Authority',
    'ADCS-Web-Enrollment',
    'ADCS-Device-Enrollment',
    'ADCS-Enroll-Web-Pol',
    'ADCS-Enroll-Web-Svc'
)

foreach ($f in $features) {
    Measure-Task "install-feature.$f" {
        $state = Get-WindowsFeature -Name $f
        if (-not $state) {
            Write-Warning "Feature $f not available on this SKU -- skipping"
            return
        }
        if ($state.InstallState -eq 'Installed') {
            Write-Host "$f already installed"
            return
        }
        $result = Install-WindowsFeature -Name $f -IncludeManagementTools -ErrorAction Stop
        if (-not $result.Success) { throw "Install-WindowsFeature -Name $f failed: $($result.ExitCode)" }
        if ($result.RestartNeeded -eq 'Yes') { Write-Host "  -> restart needed after $f" }
    }
}

Measure-Task 'verify-features-installed' {
    foreach ($f in $features) {
        $state = (Get-WindowsFeature -Name $f).InstallState
        Write-Host "  $f : $state"
    }
}

Measure-Task 'restart-winmgmt' {
    Restart-Service -Name Winmgmt -Force -ErrorAction Stop
    Start-Sleep -Seconds 15
}

Measure-Task 'verify-wmi-responsive' {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    Write-Host "WMI sanity: Win32_ComputerSystem.Name = $($cs.Name)"
}
