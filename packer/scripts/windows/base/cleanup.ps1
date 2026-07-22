# Cleanup script to reduce image size (Packer Phase 3).

$ErrorActionPreference = 'Continue'

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
    }
}

Write-Host "Cleaning up image..."

Measure-Task 'clear-windows-update-cache' {
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
}

Measure-Task 'clear-temp-files' {
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
}

Measure-Task 'clear-event-logs' {
    wevtutil cl Application
    wevtutil cl Security
    wevtutil cl System
}

Measure-Task 'compact-os' {
    Compact.exe /CompactOS:always 2>$null | Out-Null
}

# Wipe LSA autologon credentials baked in by Autounattend.xml. The unattended
# install needs AutoAdminLogon so Packer's specialize/oobe phases can run
# without an interactive console, but the FINAL image must not ship with the
# vagrant password sitting in cleartext under Winlogon.
Measure-Task 'wipe-autologon-credentials' {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    foreach ($name in 'DefaultPassword','AutoAdminLogon','DefaultUserName','DefaultDomainName') {
        $existing = Get-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
            Write-Host ("  Removed Winlogon\\{0}" -f $name)
        }
    }
}

# Re-enable Windows Firewall on all profiles. setup.ps1 turned it OFF so Packer
# could talk WinRM during the build; per-VM Ansible roles open whatever ports
# they need (WinRM/SMB/CA web enrollment/etc.) at provision time. The base
# image itself ships with the firewall ON.
# NOTE: must run AFTER all build/install steps and BEFORE any reboot — this is
# the last provisioner before the vagrant post-processor, so we're good.
Measure-Task 'enable-firewall' {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
    Write-Host "  Firewall re-enabled on Domain,Public,Private profiles"
}

# -------------------------------------------------------------------------
# OPT-IN PUBLISH MODE — gated on $env:PACKER_BUILD_FOR_PUBLISH == "1".
# Propagated from build-images.sh through the HCL provisioner's
# environment_vars block. When unset (the default lab path), this branch
# is a no-op and the script exits exactly as before.
#
# What this does when enabled:
#   1. Generate a 20-char single-use random password.
#   2. Write C:\Windows\Panther\publish-unattend.xml — an OOBE-only unattend
#      that sets that random pw as the local Administrator AND forces the
#      Windows out-of-box-experience on first boot, so the consumer is
#      prompted to set their own admin pw before the box is usable.
#   3. Print the random pw to the Packer build log (the operator needs it
#      to bridge the gap between sysprep and the consumer's first boot).
#   4. Run sysprep /generalize /oobe /shutdown /unattend:... — this shuts
#      the VM down. Packer detects the shutdown and proceeds to the
#      vagrant post-processor. shutdown_command in the HCL MUST be empty
#      in publish mode (publish_mode=true wires that up).
#
# IMPORTANT: this must be the LAST thing the cleanup script does. After
# sysprep generalize runs, WinRM is gone and the SAM is reset; any further
# provisioner step would fail.
# -------------------------------------------------------------------------
if ($env:PACKER_BUILD_FOR_PUBLISH -eq '1') {
    Measure-Task 'publish-mode-sysprep-generalize' {
        Write-Host ""
        Write-Host "============================================================"
        Write-Host " PUBLISH MODE: rotating admin pw + sysprep /generalize /oobe"
        Write-Host "============================================================"

        # Mint a single-use 20-char password (4 non-alphanumeric chars).
        # System.Web.Security loads from System.Web (full .NET FX on Windows
        # Server, always present on the base image).
        Add-Type -AssemblyName System.Web
        $oneTimePw = [System.Web.Security.Membership]::GeneratePassword(20, 4)

        Write-Host ""
        Write-Host "------------------------------------------------------------"
        Write-Host " ONE-TIME ADMINISTRATOR PASSWORD (single-use, OOBE-only):"
        Write-Host ("   {0}" -f $oneTimePw)
        Write-Host ""
        Write-Host " This password is baked into publish-unattend.xml and used"
        Write-Host " EXACTLY ONCE — by Windows OOBE on the consumer's first boot"
        Write-Host " — to gate the prompt that forces the consumer to set their"
        Write-Host " OWN admin password. It is NOT a long-lived credential."
        Write-Host " Capture it from this Packer build log if you need to debug"
        Write-Host " the brief window between sysprep and consumer first-boot."
        Write-Host "------------------------------------------------------------"
        Write-Host ""

        $pantherDir = 'C:\Windows\Panther'
        if (-not (Test-Path $pantherDir)) {
            New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
        }

        # OOBE-only unattend. AdministratorPassword sets the local Admin pw
        # during specialize; OOBE then runs interactively on first consumer
        # boot (HideOEMRegistrationScreen/HideEULAPage/etc. are NOT set, so
        # the consumer is forced through the setup flow including picking a
        # new admin password).
        $unattendPath = Join-Path $pantherDir 'publish-unattend.xml'
        # Escape & < > for XML safety. GeneratePassword can return any of
        # them in the non-alphanumeric slots.
        $xmlPw = $oneTimePw `
            -replace '&', '&amp;' `
            -replace '<', '&lt;' `
            -replace '>', '&gt;' `
            -replace '"', '&quot;'

        $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>*</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <AdministratorPassword>
          <Value>$xmlPw</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <OOBE>
        <HideEULAPage>false</HideEULAPage>
        <HideLocalAccountScreen>false</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>false</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>false</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
        Set-Content -Path $unattendPath -Value $unattend -Encoding UTF8 -Force
        Write-Host ("  Wrote {0} ({1} bytes)" -f $unattendPath, (Get-Item $unattendPath).Length)

        # Final step. sysprep /shutdown powers the VM off — Packer detects
        # that via VM state and moves on to the post-processor. Anything
        # after this point in the script will not run reliably.
        Write-Host "  Launching sysprep /generalize /oobe /shutdown ..."
        $sysprepExe = Join-Path $env:SystemRoot 'System32\Sysprep\sysprep.exe'
        Start-Process -FilePath $sysprepExe `
            -ArgumentList '/generalize','/oobe','/shutdown',"/unattend:$unattendPath" `
            -NoNewWindow
        # Give sysprep a head start so this script returns successfully
        # before the OS yanks the WinRM session out from under Packer.
        Start-Sleep -Seconds 5
    }
}

Write-Host "Cleanup complete."
