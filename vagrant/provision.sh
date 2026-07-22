#!/bin/bash
# Colorized vagrant provision wrapper with per-task timing.
# Usage: ./provision.sh vm1 [vm2...] [-- vagrant-args...]

set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR"

# Resolve active profile (sets LAB_PROFILE_NAME, VAGRANT_DOTFILE_PATH).
source "$_SCRIPT_DIR/scripts/lib/profile-helper.sh"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 vm1 [vm2...] [-- extra-vagrant-args]"
  echo "       $0 manage1"
  echo "       $0 web1 ca1"
  echo "       $0 dc1 -- --provision-with ejbca-trust"
  exit 1
fi

# Split args at -- into VMs and extra vagrant args
VMS=()
EXTRA=()
seen_sep=false
for arg in "$@"; do
  if [[ "$arg" == "--" ]]; then
    seen_sep=true
    continue
  fi
  if $seen_sep; then
    EXTRA+=("$arg")
  else
    VMS+=("$arg")
  fi
done

for vm in "${VMS[@]}"; do
  echo ""
  printf '\033[38;5;39m═══ %s ═══\033[0m\n' "$vm"
  echo ""
  t_start=$(date +%s)
  vagrant provision "$vm" "${EXTRA[@]}" 2>&1 | awk -v start="$(date +%s)" '
    function elapsed() {
      cmd = "date +%s"
      cmd | getline now
      close(cmd)
      e = now - start
      return sprintf("%dm%02ds", e/60, e%60)
    }
    /TASK \[/    {printf "\033[38;5;179m[%s] %s\033[0m\n",elapsed(),$0;next}
    /^ok: /      {printf "\033[32m%s\033[0m\n",$0;next}
    /^changed: / {printf "\033[33m%s\033[0m\n",$0;next}
    /^skipping: /{printf "\033[34m%s\033[0m\n",$0;next}
    /^(fatal|failed): /{printf "\033[31m%s\033[0m\n",$0;next}
    NR%2==0      {printf "\033[38;5;242m%s\033[0m\n",$0;next}
    1'
  rc=${PIPESTATUS[0]}
  t_end=$(date +%s)
  elapsed=$(( t_end - t_start ))
  em=$(( elapsed / 60 )); es=$(( elapsed % 60 ))
  echo ""
  if [[ $rc -eq 0 ]]; then
    printf '\033[38;5;28m✓ %s done (%dm %ds)\033[0m\n' "$vm" "$em" "$es"
  else
    printf '\033[31m✗ %s FAILED (%dm %ds)\033[0m\n' "$vm" "$em" "$es"
  fi
done
