#!/bin/bash
# Ad-hoc VirtualBox snapshot management for the Straylight lab.
# Wraps vagrant snapshot commands with topology awareness and timing.

set -euo pipefail

# ── ANSI Colors ──────────────────────────────────────────────────────────
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_STEEL=$'\033[38;5;39m'
C_GREEN=$'\033[38;5;28m'
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'

# Resolve active profile (sets LAB_PROFILE_NAME, VAGRANT_DOTFILE_PATH).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRIPT_DIR/scripts/lib/profile-helper.sh"
TOPOLOGY="$LAB_PROFILE_NAME"  # legacy var kept for the cosmetic info() lines below

# ── Usage ────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${C_STEEL}snap.sh${C_RESET} — VirtualBox snapshot management for the Straylight lab

${C_STEEL}Usage:${C_RESET}
  snap.sh save    vm1 [vm2...] [--name NAME]   Save snapshots (default: baseline)
  snap.sh restore vm1 [vm2...] [--name NAME]   Restore snapshots (default: baseline)
  snap.sh list    [vm]                          List snapshots for one or all VMs
  snap.sh delete  vm1 [vm2...] --name NAME      Delete a named snapshot

${C_STEEL}Options:${C_RESET}
  --name NAME    Snapshot name (default: "baseline")
  -h, --help     Show this help

${C_STEEL}Examples:${C_RESET}
  snap.sh save dc1 ca1                  Save "baseline" snapshot for dc1 and ca1
  snap.sh save dc1 --name post-gpo      Save a named snapshot
  snap.sh restore dc1 ca1 web1          Restore all three VMs from "baseline"
  snap.sh list                           List snapshots for all running VMs
  snap.sh list dc1                       List snapshots for dc1
  snap.sh delete dc1 --name post-gpo    Delete the "post-gpo" snapshot from dc1

${C_STEEL}Environment:${C_RESET}
  LAB_PROFILE     Active profile (default: core). Sets VAGRANT_DOTFILE_PATH.
                  See: up.sh --list-profiles

EOF
  exit "${1:-0}"
}

# ── Helpers ──────────────────────────────────────────────────────────────
fmt_time() {
  local secs="$1"
  printf "%dm%ds" $(( secs / 60 )) $(( secs % 60 ))
}

info()  { printf "${C_STEEL}==> %s${C_RESET}\n" "$*"; }
ok()    { printf "  ${C_GREEN}OK${C_RESET}  %s\n" "$*"; }
fail()  { printf "  ${C_RED}FAIL${C_RESET}  %s\n" "$*"; }
warn()  { printf "  ${C_YELLOW}WARN${C_RESET}  %s\n" "$*"; }

# ── Parse subcommand ─────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage 1

CMD="$1"; shift

case "$CMD" in
  save|restore|list|delete) ;;
  -h|--help) usage 0 ;;
  *) echo "Unknown command: $CMD"; usage 1 ;;
esac

# ── Parse remaining args ─────────────────────────────────────────────────
SNAP_NAME="baseline"
VMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -lt 2 ]] && { echo "Error: --name requires a value"; exit 1; }
      SNAP_NAME="$2"; shift 2 ;;
    -h|--help)
      usage 0 ;;
    -*)
      echo "Unknown option: $1"; usage 1 ;;
    *)
      VMS+=("$1"); shift ;;
  esac
done

# ── Subcommand implementations ───────────────────────────────────────────

do_save() {
  [[ ${#VMS[@]} -eq 0 ]] && { echo "Error: save requires at least one VM"; usage 1; }
  info "Saving snapshot \"$SNAP_NAME\" (topology: $TOPOLOGY)"
  local failures=0
  for vm in "${VMS[@]}"; do
    printf "  ${C_DIM}Saving${C_RESET} ${C_STEEL}%s${C_RESET}${C_DIM}...${C_RESET}" "$vm"
    local t_start
    t_start=$(date +%s)
    if vagrant snapshot save "$vm" "$SNAP_NAME" --force 2>&1; then
      local elapsed=$(( $(date +%s) - t_start ))
      printf "\r  ${C_GREEN}OK${C_RESET}    ${C_STEEL}%s${C_RESET}  %s\n" "$vm" "$(fmt_time $elapsed)"
    else
      printf "\r  ${C_RED}FAIL${C_RESET}  ${C_STEEL}%s${C_RESET}\n" "$vm"
      (( failures++ )) || true
    fi
  done
  [[ $failures -gt 0 ]] && return 1
  return 0
}

do_restore() {
  [[ ${#VMS[@]} -eq 0 ]] && { echo "Error: restore requires at least one VM"; usage 1; }
  info "Restoring snapshot \"$SNAP_NAME\" (topology: $TOPOLOGY)"
  local failures=0
  for vm in "${VMS[@]}"; do
    printf "  ${C_DIM}Restoring${C_RESET} ${C_STEEL}%s${C_RESET}${C_DIM}...${C_RESET}" "$vm"
    local t_start
    t_start=$(date +%s)
    if vagrant snapshot restore "$vm" "$SNAP_NAME" --no-provision 2>&1; then
      local elapsed=$(( $(date +%s) - t_start ))
      printf "\r  ${C_GREEN}OK${C_RESET}    ${C_STEEL}%s${C_RESET}  %s\n" "$vm" "$(fmt_time $elapsed)"
    else
      printf "\r  ${C_RED}FAIL${C_RESET}  ${C_STEEL}%s${C_RESET}\n" "$vm"
      (( failures++ )) || true
    fi
  done
  [[ $failures -gt 0 ]] && return 1
  return 0
}

do_list() {
  if [[ ${#VMS[@]} -eq 0 ]]; then
    info "Listing snapshots for all VMs (topology: $TOPOLOGY)"
    vagrant snapshot list 2>&1 || true
  else
    for vm in "${VMS[@]}"; do
      info "Snapshots for $vm"
      vagrant snapshot list "$vm" 2>&1 || true
    done
  fi
}

do_delete() {
  [[ ${#VMS[@]} -eq 0 ]] && { echo "Error: delete requires at least one VM"; usage 1; }
  info "Deleting snapshot \"$SNAP_NAME\" (topology: $TOPOLOGY)"
  local failures=0
  for vm in "${VMS[@]}"; do
    printf "  ${C_DIM}Deleting${C_RESET} ${C_STEEL}%s${C_RESET}${C_DIM}...${C_RESET}" "$vm"
    if vagrant snapshot delete "$vm" "$SNAP_NAME" 2>&1; then
      printf "\r  ${C_GREEN}OK${C_RESET}    ${C_STEEL}%s${C_RESET}\n" "$vm"
    else
      printf "\r  ${C_RED}FAIL${C_RESET}  ${C_STEEL}%s${C_RESET}\n" "$vm"
      (( failures++ )) || true
    fi
  done
  [[ $failures -gt 0 ]] && return 1
  return 0
}

# ── Dispatch ─────────────────────────────────────────────────────────────
case "$CMD" in
  save)    do_save    ;;
  restore) do_restore ;;
  list)    do_list    ;;
  delete)  do_delete  ;;
esac
