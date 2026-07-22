#!/bin/bash
# Start all VirtualBox VMs that are not currently running.

if ! command -v VBoxManage >/dev/null 2>&1; then
  echo "Error: VBoxManage not found on PATH." >&2
  exit 1
fi

# Capture the VM list separately so a VBoxManage failure isn't masked by the
# pipe (the old `VBoxManage list vms | awk | while` swallowed the exit status).
if ! vm_list=$(VBoxManage list vms 2>&1); then
  echo "Error: 'VBoxManage list vms' failed:" >&2
  echo "$vm_list" >&2
  exit 1
fi

if [[ -z "$vm_list" ]]; then
  echo "Warning: no VirtualBox VMs registered — nothing to start." >&2
  exit 0
fi

echo "$vm_list" | awk -F'"' '{print $2}' | while read -r vm; do
  VBoxManage startvm "$vm" --type headless 2>/dev/null && echo "Started: $vm" || echo "Skip: $vm"
done
