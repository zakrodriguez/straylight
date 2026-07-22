#!/bin/bash
# lab-secrets.sh — resolve lab credentials/endpoints from the active
# profile's generated group_vars instead of hardcoded fallbacks.
#
# Source AFTER profile-helper.sh (needs LAB_PROFILE_NAME).
#
#   lab_groupvar KEY   — print the value of a top-level scalar key from
#                        ansible/inventory/<profile>/group_vars/all.yml.
#                        Fails loudly (non-zero + stderr hint) when the file
#                        or key is missing — callers under `set -e` abort
#                        instead of silently using a stale default.
#
# Override the file with LAB_GROUPVARS_FILE (used by tests).

_LAB_SECRETS_VAGRANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

lab_groupvar() {
  local key="$1"
  local gv="${LAB_GROUPVARS_FILE:-$_LAB_SECRETS_VAGRANT_DIR/ansible/inventory/$LAB_PROFILE_NAME/group_vars/all.yml}"
  if [[ ! -f "$gv" ]]; then
    echo "[lab-secrets] group_vars not found: $gv" >&2
    echo "[lab-secrets] run scripts/render-inventory.sh (or any vagrant command) to generate it" >&2
    return 1
  fi
  local val
  val=$(sed -n "s/^${key}:[[:space:]]*//p" "$gv" | head -1)
  # Strip optional surrounding quotes (generated YAML quotes some scalars).
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  if [[ -z "$val" ]]; then
    echo "[lab-secrets] key '$key' not found in $gv" >&2
    return 1
  fi
  printf '%s\n' "$val"
}

# lab_vm_ip <vm> — active profile's IP for <vm> from rendered ansible_host=.
# Reads the per-profile static.ini so it is subnet-correct and covers VMs absent
# from group_vars (scanner1/acme1/apps1). Empty (rc 0) if inventory not rendered.
lab_vm_ip() {
  local vm="$1"
  local inv="${LAB_INVENTORY_FILE:-$_LAB_SECRETS_VAGRANT_DIR/ansible/inventory/$LAB_PROFILE_NAME/static.ini}"
  [[ -f "$inv" ]] || return 0
  awk -v vm="$vm" '$1==vm{for(i=2;i<=NF;i++) if($i ~ /^ansible_host=/){sub(/^ansible_host=/,"",$i);print $i;exit}}' "$inv"
}

# lab_network [vm] — first three octets of the active profile's /24 (default via any host).
lab_network() {
  local ip; ip="$(lab_vm_ip "${1:-dc1}")"
  [[ -z "$ip" ]] && ip="$(lab_vm_ip stepca1)"   # Linux-only profiles have no dc1
  [[ -n "$ip" ]] && printf '%s\n' "${ip%.*}"
  return 0   # never fail the caller — callers run under `set -e` and treat empty
             # output as "use the literal fallback", not as an error.
}
