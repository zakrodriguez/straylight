# Patch baseline.
#
# DECISION: straylight boxes ship UNPATCHED. The lab's patch path is the
# RUNTIME WSUS golden-master loop (the `wsus_server` Ansible role +
# vagrant/scripts/cache-wsus.sh), NOT a baked update snapshot. Baking updates
# here would duplicate the WSUS cache as dead weight inside every box, go
# stale at the next Patch Tuesday, and re-introduce the build-to-build drift
# that the box-versioning contract exists to remove. See packer/README.md
# ("Patch baseline: runtime WSUS, not a baked snapshot") for the full rationale.
#
# This script therefore only stages the PSWindowsUpdate module (cheap, lets a
# consumer run updates on demand inside a baked VM) and intentionally does NOT
# apply updates. To experiment with a baked baseline, uncomment the
# Get-WindowsUpdate line below — but the supported, reproducible path is WSUS.

Write-Host "Staging PSWindowsUpdate module (updates are NOT applied at bake time — patch baseline is runtime WSUS)..."

# Install PSWindowsUpdate module if not present
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module PSWindowsUpdate -Force
}

# Import module
Import-Module PSWindowsUpdate

# Intentionally disabled — see DECISION above. Uncomment ONLY to bake a
# point-in-time update baseline (not the supported path):
# Get-WindowsUpdate -AcceptAll -Install -AutoReboot

Write-Host "PSWindowsUpdate staged; no updates applied (runtime WSUS owns patching)."
