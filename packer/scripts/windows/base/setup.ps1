# Packer base provisioning scripts for Windows Server images
# These scripts configure the base image before Vagrant provisioning

Write-Host "Starting base image setup..."

# Set execution policy
Set-ExecutionPolicy Unrestricted -Force

# Enable WinRM for Packer/Vagrant communication
winrm quickconfig -q
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="2048"}'
winrm set winrm/config '@{MaxTimeoutms="7200000"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# Disable Windows Firewall for lab environment
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Enable Remote Desktop
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

Write-Host "Base setup complete."
