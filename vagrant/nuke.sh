#!/bin/bash
# Destroy lab VMs in preparation for a fresh build.
# Includes safeguards to prevent accidental runs.

set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR"

# ── Colors ─────────────────────────────────────────────────────────────
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_CYAN=$'\033[38;5;39m'
C_GREEN=$'\033[38;5;28m'
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'

# Resolve active profile (sets LAB_PROFILE_NAME, LAB_PROFILE_COMPONENTS_ARR,
# VAGRANT_DOTFILE_PATH). nuke.sh only ever sees VMs in this profile because
# `vagrant status` is scoped to the dotfile path.
source "$_SCRIPT_DIR/scripts/lib/profile-helper.sh"
TOPOLOGY="$LAB_PROFILE_NAME"  # legacy var; cosmetic only

# ── Usage ──────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${C_CYAN}nuke.sh${C_RESET} — destroy lab VMs for a fresh build

${C_CYAN}Usage:${C_RESET}
  nuke.sh                        Dry run — show what would be destroyed
  nuke.sh --confirm              Destroy all VMs (with NUKE confirmation)
  nuke.sh --keep vm1,vm2         Destroy all VMs EXCEPT the listed ones
  nuke.sh --only vm1,vm2         Destroy ONLY the listed VMs
  nuke.sh --yes-delete-without-prompt   Skip confirmation prompt (for scripts)

${C_CYAN}Options:${C_RESET}
  --confirm        Actually destroy (default is dry run)
  --keep vm1,vm2   Preserve specified VMs and their snapshots
  --only vm1,vm2   Destroy only specified VMs
  --dry-run        Preview without destroying anything (default)
  --yes-delete-without-prompt  Skip all prompts and destroy immediately (you asked for it)
  -h, --help       Show this help

${C_CYAN}Examples:${C_RESET}
  nuke.sh                         See what would be destroyed (safe)
  nuke.sh --confirm --keep dc1,manage1   Destroy everything except dc1 and manage1
  nuke.sh --confirm --only web1,ca1      Destroy only web1 and ca1
  nuke.sh --yes-delete-without-prompt --only ca1      Destroy ca1, no questions asked

${C_CYAN}Environment:${C_RESET}
  LAB_PROFILE     Active profile (default: core). nuke.sh only operates on
                  VMs defined in this profile. See: up.sh --list-profiles
  NUKE_PARALLELISM  Max concurrent `vagrant destroy` ops (default: 8). VMs are
                  hard-powered-off first, then destroyed in parallel.

${C_RED}WARNING:${C_RESET} Destroyed VMs lose ALL snapshots. Use --keep to preserve them.

EOF
  exit "${1:-0}"
}

# ── Parse args ─────────────────────────────────────────────────────────
KEEP_LIST=""
ONLY_LIST=""
DRY_RUN=true
AUTO_YES=false
CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      [[ $# -lt 2 ]] && { echo "Error: --keep requires a VM list"; exit 1; }
      KEEP_LIST="$2"; shift 2 ;;
    --only)
      [[ $# -lt 2 ]] && { echo "Error: --only requires a VM list"; exit 1; }
      ONLY_LIST="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --confirm)  CONFIRM=true; DRY_RUN=false; shift ;;
    --yes-delete-without-prompt)  AUTO_YES=true; DRY_RUN=false; shift ;;
    -h|--help)  usage 0 ;;
    *)          echo "Unknown option: $1"; usage 1 ;;
  esac
done

if [[ -n "$KEEP_LIST" && -n "$ONLY_LIST" ]]; then
  echo "Error: --keep and --only are mutually exclusive"
  exit 1
fi

# ── Build keep/only lookup tables ──────────────────────────────────────
declare -A KEEP_VM
if [[ -n "$KEEP_LIST" ]]; then
  IFS=',' read -ra _vms <<< "$KEEP_LIST"
  for vm in "${_vms[@]}"; do KEEP_VM[$vm]=1; done
fi

declare -A ONLY_VM
if [[ -n "$ONLY_LIST" ]]; then
  IFS=',' read -ra _vms <<< "$ONLY_LIST"
  for vm in "${_vms[@]}"; do ONLY_VM[$vm]=1; done
fi

# ── Discover VMs ───────────────────────────────────────────────────────
ALL_VMS=()
while IFS=, read -r _ts vm _rest; do
  ALL_VMS+=("$vm")
done < <(vagrant status --machine-readable 2>/dev/null | grep ',metadata,provider,')

if [[ ${#ALL_VMS[@]} -eq 0 ]]; then
  echo "${C_DIM}No VMs found for profile: ${LAB_PROFILE_NAME} (dotfile: ${VAGRANT_DOTFILE_PATH})${C_RESET}"
  exit 0
fi

# Safety: refuse to operate on VMs outside the active profile. (--only and
# --keep are user-supplied, so this catches typos like nuking 'observer1'.)
if [[ -n "$ONLY_LIST" ]]; then
  for vm in "${!ONLY_VM[@]}"; do
    if ! profile_has "$vm"; then
      echo "${C_RED}Refusing to operate on '$vm' — not in active profile '$LAB_PROFILE_NAME'.${C_RESET}"
      echo "${C_DIM}Active components: ${LAB_PROFILE_COMPONENTS_ARR[*]}${C_RESET}"
      exit 1
    fi
  done
fi
if [[ -n "$KEEP_LIST" ]]; then
  for vm in "${!KEEP_VM[@]}"; do
    if ! profile_has "$vm"; then
      echo "${C_YELLOW}WARN: --keep '$vm' is not in active profile '$LAB_PROFILE_NAME' (no-op).${C_RESET}"
    fi
  done
fi

# ── Determine which VMs to destroy ─────────────────────────────────────
DESTROY_VMS=()
PRESERVE_VMS=()

for vm in "${ALL_VMS[@]}"; do
  if [[ -n "$ONLY_LIST" ]]; then
    # --only mode: destroy only listed VMs
    if [[ -n "${ONLY_VM[$vm]:-}" ]]; then
      DESTROY_VMS+=("$vm")
    else
      PRESERVE_VMS+=("$vm")
    fi
  elif [[ -n "$KEEP_LIST" ]]; then
    # --keep mode: destroy everything except listed VMs
    if [[ -n "${KEEP_VM[$vm]:-}" ]]; then
      PRESERVE_VMS+=("$vm")
    else
      DESTROY_VMS+=("$vm")
    fi
  else
    # default: destroy all
    DESTROY_VMS+=("$vm")
  fi
done

if [[ ${#DESTROY_VMS[@]} -eq 0 ]]; then
  echo "${C_GREEN}Nothing to destroy${C_RESET} — all VMs are preserved."
  exit 0
fi

# ── Preview ────────────────────────────────────────────────────────────
echo ""
echo "${C_CYAN}nuke.sh${C_RESET} ${C_DIM}— profile: ${LAB_PROFILE_NAME} (dotfile: ${VAGRANT_DOTFILE_PATH})${C_RESET}"
echo ""

# Get VM states for display
declare -A VM_STATE
while IFS=, read -r _ts vm state _rest; do
  VM_STATE[$vm]="$state"
done < <(vagrant status --machine-readable 2>/dev/null | grep ',state,')

echo "${C_RED}Destroy:${C_RESET}"
for vm in "${DESTROY_VMS[@]}"; do
  state="${VM_STATE[$vm]:-unknown}"
  case "$state" in
    running)    state_color="$C_GREEN" ;;
    saved|aborted) state_color="$C_YELLOW" ;;
    not_created) state_color="$C_DIM" ;;
    *)          state_color="$C_DIM" ;;
  esac
  printf "  ${C_RED}✗${C_RESET}  %-12s ${state_color}%s${C_RESET}\n" "$vm" "$state"
done

if [[ ${#PRESERVE_VMS[@]} -gt 0 ]]; then
  echo ""
  echo "${C_GREEN}Preserve:${C_RESET}"
  for vm in "${PRESERVE_VMS[@]}"; do
    state="${VM_STATE[$vm]:-unknown}"
    printf "  ${C_GREEN}✓${C_RESET}  %-12s ${C_DIM}%s${C_RESET}\n" "$vm" "$state"
  done
fi

echo ""

if $DRY_RUN; then
  echo "${C_YELLOW}DRY RUN${C_RESET} — no VMs were destroyed."
  exit 0
fi

# ── Confirmation ───────────────────────────────────────────────────────
if ! $AUTO_YES; then
  echo "${C_RED}This will permanently destroy ${#DESTROY_VMS[@]} VM(s) and their snapshots.${C_RESET}"
  printf "Type ${C_RED}NUKE${C_RESET} to confirm: "
  read -r confirm
  if [[ "$confirm" != "NUKE" ]]; then
    echo "${C_DIM}Aborted.${C_RESET}"
    exit 0
  fi
  echo ""
fi

# ── Destroy (parallel + hard-poweroff) ─────────────────────────────────
# Two speedups over a serial `vagrant destroy` loop (which idled ~5-6 min on a
# 13-VM profile):
#   1. Hard-poweroff running targets up front via VBoxManage (instant) so
#      `vagrant destroy` doesn't block on a 10-30s ACPI graceful shutdown.
#   2. Run the destroys concurrently — vagrant locks per-machine, so distinct
#      VMs are safe — capped at NUKE_PARALLELISM in-flight so big profiles don't
#      spawn dozens of Ruby processes at once.
# Each destroy records its exit code to a per-VM status file, so results are
# collected reliably regardless of the throttle's `wait -n` reaping order.
NUKE_PARALLELISM="${NUKE_PARALLELISM:-8}"

# 1. Hard-poweroff every running target (parallel, instant). Best-effort: a
#    failure here just falls back to vagrant destroy's own ACPI shutdown.
if [[ -n "${LAB_VBOX_PREFIX:-}" ]]; then
  _poweroff_pids=()
  for vm in "${DESTROY_VMS[@]}"; do
    [[ "${VM_STATE[$vm]:-}" == "running" ]] || continue
    VBoxManage controlvm "${LAB_VBOX_PREFIX}-${vm}" poweroff >/dev/null 2>&1 &
    _poweroff_pids+=("$!")
  done
  if [[ ${#_poweroff_pids[@]} -gt 0 ]]; then
    wait "${_poweroff_pids[@]}" 2>/dev/null || true
  fi
fi

# 2. Destroy concurrently, capped at NUKE_PARALLELISM in-flight.
_status_dir="$(mktemp -d)"
trap 'rm -rf "$_status_dir"' EXIT
for vm in "${DESTROY_VMS[@]}"; do
  if [[ "${VM_STATE[$vm]:-unknown}" == "not_created" ]]; then
    printf "  ${C_DIM}skip${C_RESET}  %-12s ${C_DIM}(not created)${C_RESET}\n" "$vm"
    continue
  fi
  while (( $(jobs -rp | wc -l) >= NUKE_PARALLELISM )); do wait -n 2>/dev/null || true; done
  # `|| rc=$?` captures the exit without tripping `set -e`, so a FAILED destroy
  # still writes its status file (and gets counted) instead of aborting the subshell.
  ( rc=0; vagrant destroy "$vm" -f >/dev/null 2>&1 || rc=$?; echo "$rc" > "$_status_dir/$vm" ) &
done
wait 2>/dev/null || true

# 3. Aggregate results in stable (destroy-list) order.
failures=0
for vm in "${DESTROY_VMS[@]}"; do
  [[ -f "$_status_dir/$vm" ]] || continue
  if [[ "$(cat "$_status_dir/$vm")" == "0" ]]; then
    printf "  ${C_GREEN}done${C_RESET}  %-12s\n" "$vm"
  else
    printf "  ${C_RED}FAIL${C_RESET}  %-12s\n" "$vm"
    (( failures++ )) || true
  fi
done

echo ""
if [[ $failures -gt 0 ]]; then
  echo "${C_RED}$failures VM(s) failed to destroy.${C_RESET}"
  exit 1
else
  echo "${C_GREEN}Done.${C_RESET} Destroyed ${#DESTROY_VMS[@]} VM(s)."
  if [[ ${#PRESERVE_VMS[@]} -gt 0 ]]; then
    echo "${C_DIM}Preserved: $(IFS=,; echo "${PRESERVE_VMS[*]}")${C_RESET}"
  fi
fi
