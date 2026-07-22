#!/bin/bash
# scripts/lib/vm-registry.sh — VM identity from topology.yml.
# The single bash view of the VM table. Source anywhere; the taxonomy helpers
# need no profile, but vm_ip/vm_network now resolve the lab's dynamic /24 from
# the active profile's rendered inventory (so they need LAB_PROFILE_NAME set).
#
#   vm_all              all canonical VM names (one per line)
#   vm_ip <name>        full IP
#   vm_os <name>        windows|linux
#   vm_windows          windows VM names
#   vm_linux            linux VM names
#   vm_groups <name>    space-separated groups
#
# Uses `yq` if available, else an awk fallback (pattern from lab-secrets.sh).
_VMREG_TOPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/topology.yml"

# topology.yml's `network` is now only the dynamic allocation START — each lab
# gets its OWN /24 (lowest free 3rd octet, see lib/lab_network.rb), so it is NOT
# any running lab's real subnet. vm_ip/vm_network therefore resolve the live /24
# from the active profile's rendered inventory via lab_vm_ip/lab_network.
# shellcheck source=scripts/lib/lab-secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/lab-secrets.sh"

_vmreg_have_yq() { command -v yq >/dev/null 2>&1; }

vm_all() {
  if _vmreg_have_yq; then yq -r '.vms | keys | .[]' "$_VMREG_TOPO"
  else awk '/^vms:/{f=1;next} f&&/^  [A-Za-z0-9_-]+:/{gsub(/[ :]/,"");print}' "$_VMREG_TOPO"; fi
}
# Live /24 of the active profile (dynamic — NOT topology.yml's `network`).
# An explicit LAB_NETWORK wins; otherwise derive it from the rendered inventory.
vm_network() { printf '%s\n' "${LAB_NETWORK:-$(lab_network)}"; }
vm_field() {  # vm_field <name> <field>
  local name="$1" field="$2"
  if _vmreg_have_yq; then yq -r ".vms.\"$name\".$field // \"\"" "$_VMREG_TOPO"
  else awk -v vm="$name" -v fld="$field" '
        $0=="  "vm":"{inv=1;next}
        inv&&/^  [A-Za-z0-9_-]+:/{inv=0}
        inv&&$1==fld":"{ $1=""; sub(/^ +/,""); print; exit }' "$_VMREG_TOPO"; fi
}
# Subnet-correct IP from the active profile's rendered inventory (dynamic /24).
vm_ip()     { lab_vm_ip "$1"; }
vm_os()     { vm_field "$1" os; }
vm_groups() { vm_field "$1" groups | tr -d '[]' ; }
vm_windows(){ local n; for n in $(vm_all); do [[ "$(vm_os "$n")" == windows ]] && echo "$n"; done; }
vm_linux()  { local n; for n in $(vm_all); do [[ "$(vm_os "$n")" == linux   ]] && echo "$n"; done; }
