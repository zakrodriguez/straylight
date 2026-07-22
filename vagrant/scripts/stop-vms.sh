#!/bin/bash
# Stop all running VirtualBox VMs. Default: savestate. Use --force to poweroff.
MODE="savestate"
[[ "${1:-}" == "--force" ]] && MODE="poweroff"

if ! command -v VBoxManage >/dev/null 2>&1; then
  echo "Error: VBoxManage not found on PATH." >&2
  exit 1
fi

# Capture the running-VM list separately so a VBoxManage failure isn't masked
# by the pipe (the old `VBoxManage list runningvms | awk | while` swallowed it).
if ! vm_list=$(VBoxManage list runningvms 2>&1); then
  echo "Error: 'VBoxManage list runningvms' failed:" >&2
  echo "$vm_list" >&2
  exit 1
fi

if [[ -z "$vm_list" ]]; then
  echo "Warning: no running VirtualBox VMs — nothing to stop." >&2
  exit 0
fi

echo "$vm_list" | awk -F'"' '{print $2}' | while read -r vm; do
  VBoxManage controlvm "$vm" "$MODE" 2>/dev/null && echo "Stopped: $vm ($MODE)" || echo "Skip: $vm"
done
