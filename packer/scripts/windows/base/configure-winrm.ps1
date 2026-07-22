# Configure WinRM for Vagrant communication

Write-Host "Configuring WinRM..."

# Delete existing WinRM listeners
winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null
winrm delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null

# Create new HTTP listener
winrm create winrm/config/Listener?Address=*+Transport=HTTP

# Configure WinRM service
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service/auth '@{CredSSP="true"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="2048"}'
winrm set winrm/config '@{MaxTimeoutms="7200000"}'

# Set WinRM service to auto-start
Set-Service -Name WinRM -StartupType Automatic
Restart-Service WinRM

# Allow WinRM through firewall
netsh advfirewall firewall add rule name="WinRM HTTP" dir=in action=allow protocol=TCP localport=5985

Write-Host "WinRM configured successfully."
