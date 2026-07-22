#!/bin/bash
# Three-phase lab build: sequential create, provision DC1, provision rest in parallel.
# Phase 1: Create all VMs sequentially (avoids Vagrant lock contention).
# Phase 2: Provision DC1 (AD DS must be up before anything else).
# Phase 3: Provision remaining VMs in parallel (retry loops handle dependencies).

POLL="${VM_POLL:-15}"          # seconds between progress updates (default 15s, set VM_POLL in env)
ALL=false
VM_FILE=""
SAVE_SNAP=""
RESTORE_SNAP=""
REBUILD_VM=""

usage() {
  echo "Usage: $0 [--all] [--file FILE] [--poll SECONDS]"
  echo "       $0 --save-snap vm1,vm2|all"
  echo "       $0 --restore-snap vm1,vm2|all"
  echo "       $0 --rebuild vm1[,vm2,...]"
  echo "       $0 --list-profiles"
  echo "       $0 --show-profile NAME"
  echo ""
  echo "  --all                    Build everything in the 'full' profile (alias)"
  echo "  --file FILE              Read VM list from file (one per line, dc1 always first)"
  echo "  --poll SECONDS           Progress update interval (default: 15)"
  echo "                           (LAB_BUILDMON=off disables the buildmon auto-attach)"
  echo "  --save-snap vm1,vm2|all  Snapshot VMs after successful build"
  echo "  --restore-snap vm1,vm2|all  Restore VMs from snapshot instead of building"
  echo "  --rebuild vm1[,vm2,...]  Destroy and rebuild VMs from scratch (dc1 not allowed)"
  echo "  --list-profiles          List all available LAB_PROFILE values and exit"
  echo "  --show-profile NAME      Print components/resources for a profile and exit"
  echo ""
  echo "Three-phase build:"
  echo "  1. Create all VMs sequentially (no lock contention)"
  echo "  2. Provision DC1 (AD DS forest, DNS, OUs)  — skipped if dc1 not in profile"
  echo "  3. Provision remaining VMs in parallel"
  echo ""
  echo "Profile selection (lowest priority → highest):"
  echo "  default            -> core profile (dc1, manage1, web1, ca1)"
  echo "  LAB_PROFILE=X      -> picks vagrant/profiles/X.yml"
  echo "  LAB_COMPONENTS=...  -> ad-hoc comma-separated component list"
  echo ""
  echo "  Examples:"
  echo "    LAB_PROFILE=pqc-linux $0          # six Linux VMs, no AD"
  echo "    LAB_PROFILE=ad-cs-minimal $0      # 2 GB, two-VM AD CS"
  echo "    LAB_COMPONENTS=observe1,scanner1 $0"
  echo ""
  echo "Snapshots:"
  echo "  First build:   $0 --save-snap dc1,manage1     # snapshot named 'baseline'"
  echo "  Fast rebuild:  $0 --restore-snap dc1,manage1  # explicit restore list"
  echo "  Auto-restore:  $0                             # detects 'baseline' snapshots"
  echo "                                                  on running VMs; disable with"
  echo "                                                  LAB_AUTO_RESTORE_BASELINE=false"
  echo ""
  echo "Rebuild (destroy + recreate + provision):"
  echo "  $0 --rebuild ca1"
  echo "  $0 --rebuild web1,client1"
  exit 1
}

# Pre-parse: handle the two info-only flags before sourcing anything heavy.
# --list-profiles intentionally bypasses profile-helper.sh so that listing
# still works when the resolver would error (e.g. stale ADCS_TOPOLOGY set).
case "${1:-}" in
  --list-profiles)
    echo "Available profiles (vagrant/profiles/*.yml):"
    ruby -I "$(dirname "$0")/lib" -r lab_profile -e '
      require "yaml"
      LabProfile.available_profiles.each do |name|
        yaml_path = File.join(LabProfile::PROFILES_DIR, "#{name}.yml")
        desc = (YAML.load_file(yaml_path)["description"] || "").strip.lines.first.to_s.strip
        puts "  #{name.ljust(22)} #{desc}"
      end
    '
    exit 0
    ;;
  --show-profile)
    [[ -z "${2:-}" ]] && { echo "ERROR: --show-profile requires a NAME"; exit 1; }
    LAB_PROFILE="$2" source "$(dirname "$0")/scripts/lib/profile-helper.sh"
    echo "Profile: $LAB_PROFILE_NAME"
    echo "Source:  $LAB_PROFILE_SOURCE"
    echo "Dotfile: $LAB_DOTFILE_DIR"
    echo "VBox prefix: $LAB_VBOX_PREFIX"
    echo "Components (${#LAB_PROFILE_COMPONENTS_ARR[@]}):"
    for c in "${LAB_PROFILE_COMPONENTS_ARR[@]}"; do echo "  - $c"; done
    exit 0
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)           ALL=true; shift ;;
    --file)          VM_FILE="$2"; shift 2 ;;
    --poll)          POLL="$2"; shift 2 ;;
    --save-snap)     SAVE_SNAP="$2"; shift 2 ;;
    --restore-snap)  RESTORE_SNAP="$2"; shift 2 ;;
    --rebuild)       REBUILD_VM="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *)               echo "Unknown option: $1"; usage ;;
  esac
done

# Parse restore list into lookup table
declare -A RESTORE_VM
if [[ -n "$RESTORE_SNAP" && "$RESTORE_SNAP" != "all" ]]; then
  IFS=',' read -ra _snap_vms <<< "$RESTORE_SNAP"
  for vm in "${_snap_vms[@]}"; do RESTORE_VM[$vm]=1; done
fi

# Parse save list into lookup table
declare -A SAVE_VM
if [[ -n "$SAVE_SNAP" && "$SAVE_SNAP" != "all" ]]; then
  IFS=',' read -ra _snap_vms <<< "$SAVE_SNAP"
  for vm in "${_snap_vms[@]}"; do SAVE_VM[$vm]=1; done
fi

# Check if a VM has a 'baseline' snapshot saved (Sprint 3 path A, 2026-05-23).
# Cached per VM so we don't re-shell-out to `vagrant snapshot list` repeatedly.
declare -A _HAS_BASELINE_CACHE
has_baseline_snap() {
  local vm="$1"
  if [[ -z "${_HAS_BASELINE_CACHE[$vm]:-}" ]]; then
    if vagrant snapshot list "$vm" 2>/dev/null | grep -qx 'baseline'; then
      _HAS_BASELINE_CACHE[$vm]=1
    else
      _HAS_BASELINE_CACHE[$vm]=0
    fi
  fi
  [[ "${_HAS_BASELINE_CACHE[$vm]}" == "1" ]]
}

# Check if a VM should be restored from snapshot.
# Auto-detect: if LAB_AUTO_RESTORE_BASELINE=true (default) and a `baseline`
# snapshot exists for this VM, restore even without explicit --restore-snap.
# Disable with LAB_AUTO_RESTORE_BASELINE=false on the up.sh invocation.
should_restore() {
  [[ "$RESTORE_SNAP" == "all" ]] && return 0
  [[ -n "${RESTORE_VM[$1]:-}" ]] && return 0
  if [[ "${LAB_AUTO_RESTORE_BASELINE:-true}" == "true" ]]; then
    has_baseline_snap "$1" && return 0
  fi
  return 1
}

# Check if a VM should be snapshotted after build
should_save() {
  [[ "$SAVE_SNAP" == "all" ]] && return 0
  [[ -n "${SAVE_VM[$1]:-}" ]] && return 0
  return 1
}

# Save a snapshot for a VM (call after successful build)
save_snap() {
  local vm="$1"
  printf "  ${C_DIM}Saving snapshot for ${C_RESET}${C_CYAN}%s${C_RESET}${C_DIM}...${C_RESET}" "$vm"
  if _vagrant_retry_lock "$LOGDIR/$vm-snap.log" snapshot save "$vm" baseline --force; then
    printf " ${C_GREEN}done${C_RESET}\n"
  else
    printf " ${C_RED}failed${C_RESET} (see $LOGDIR/$vm-snap.log)\n"
  fi
}

# Load .env (generated by install-wizard.sh) without clobbering vars the
# user already set: an inline `LAB_PROFILE=x bash up.sh` must beat the
# wizard's file. A bare `source` did the opposite — assignment to an
# already-exported var updates the environment, so the .env value leaked
# over the inline one. Export each value so child processes (the ruby
# resolver in profile-helper.sh, vagrant itself) actually see it; a bare
# sourced assignment was a shell variable only and children resolved the
# 'core' default.
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r k v; do
    k="${k#export }"
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!k:-}" ]] || export "$k=$v"
  done < "$ENV_FILE"
fi

LAB_DOMAIN="${LAB_DOMAIN:-yourlab.local}"
ANSIBLE_DIR="$(cd "$(dirname "$0")/ansible" && pwd)"

# Resolve active profile via shared helper. Sets:
#   LAB_PROFILE_NAME, LAB_PROFILE_COMPONENTS_ARR, LAB_DOTFILE_DIR,
#   LAB_VBOX_PREFIX, VAGRANT_DOTFILE_PATH (exported), profile_has(),
#   list_profiles().
source "$(dirname "$0")/scripts/lib/profile-helper.sh"

# Inventory generation is an explicit step: the Vagrantfile only
# (re)writes static.ini / pqc.ini / group_vars/all.yml when this flag is set.
# A bare `vagrant status` (or tab-completion) no longer mutates shared files.
export LAB_RENDER_INVENTORY=1

# Derived TOPOLOGY for the few legacy paths that still reference it (logs,
# warnings). New code uses profile_has() instead.
TOPOLOGY="${LAB_PROFILE_NAME}"

# Per-VM log directory
LOGDIR="logs/$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$LOGDIR"

echo "Profile: $LAB_PROFILE_NAME (${#LAB_PROFILE_COMPONENTS_ARR[@]} VMs, dotfile: $VAGRANT_DOTFILE_PATH)"
echo "Components: ${LAB_PROFILE_COMPONENTS_ARR[*]}"
echo "VM logs: $LOGDIR/"
echo ""

# ── buildmon auto-launch (LAB_BUILDMON=off to disable) ────────────────────
# Attach the observer sidecar to this build's logdir, pinned to the resolved
# profile (bare inference is fine since v2.4.1, but explicit is free here and
# immune to equal-set ambiguity when a twin lab is standing). Strictly
# best-effort: a broken/missing buildmon must never touch the build.
if [[ "${LAB_BUILDMON:-on}" != "off" ]]; then
  if bash "$(dirname "$0")/scripts/buildmon.sh" -l "$LOGDIR" -p "$LAB_PROFILE_NAME" start >/dev/null 2>&1; then
    echo "buildmon: collector attached (live view: bash scripts/buildmon.sh -l $LOGDIR)"
  else
    echo "buildmon: auto-launch failed — build continues (manual: bash scripts/buildmon.sh -l $LOGDIR -p $LAB_PROFILE_NAME)"
  fi
  echo ""
fi

# Record a VM's backgrounded provision PID for buildmon (best-effort, never
# fatal). buildmon's collector reads <logdir>/<vm>.pid to populate
# pid_alive, which gates its "rebooting" state detection; without this file
# that detection silently never fires (2026-07-06 live-build finding).
# Defined here (before the rebuild-mode block below) rather than near
# launch_vm/restore_vm so it's registered for every call site, including
# the early --rebuild path.
write_pidfile() {
  local vm="$1" pid="$2"
  echo "$pid" > "$LOGDIR/$vm.pid" 2>/dev/null || true
}

BUILD_START="$(date +%s)"

# ── Colors ─────────────────────────────────────────────────────────────
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_CYAN=$'\033[38;5;39m'
C_WHITE=$'\033[97m'
C_GREEN=$'\033[38;5;28m'
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_MAGENTA=$'\033[35m'

declare -A VM_COLOR
_COLORS=("$C_CYAN" "$C_GREEN" "$C_YELLOW" "$C_BLUE" "$C_MAGENTA" "$C_WHITE" "$C_RED")
_ci=0

# Assign next color to a VM
assign_color() {
  VM_COLOR[$1]="${_COLORS[$(( _ci % ${#_COLORS[@]} ))]}"
  _ci=$((_ci + 1))
}

# Format elapsed build time as XmYs
elapsed_total() {
  local e=$(( $(date +%s) - BUILD_START ))
  printf "%dm%ds" $(( e / 60 )) $(( e % 60 ))
}

# Run a vagrant command, retrying when the failure is Vagrant's transient
# machine-action lock ("Vagrant can't use the requested machine because it is
# locked!"): the flock in ~/.vagrant.d/data is acquired with no retry, so a
# momentary overlap with any other vagrant process on the host — including a
# second lab building concurrently — kills an otherwise healthy operation.
# Output appends to LOG; lock detection only looks at the portion the current
# attempt wrote (an earlier attempt's lock error would otherwise mask a
# different failure).
_vagrant_retry_lock() {
  local log="$1"; shift
  local attempt max_attempts=4 log_ofs   # 1 initial + 3 lock retries
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    log_ofs=0
    [[ -f "$log" ]] && log_ofs=$(wc -c < "$log")
    vagrant "$@" >> "$log" 2>&1 && return 0
    if [[ $attempt -lt $max_attempts ]] \
       && tail -c +"$(( log_ofs + 1 ))" "$log" | grep -q "requested machine because it is locked"; then
      sleep 10
    else
      return 1
    fi
  done
  return 1
}

# Create a VM without provisioning (sequential, holds lock briefly).
# Retries up to three times on the transient machine lock (see
# _vagrant_retry_lock; saw this on the two-tier dc1/manage1 creates 2026-07-01
# with three labs building at once), with progress output per attempt.
#
# The lock error can also strike AFTER `vagrant up` has powered the VM on
# (during "Waiting for machine to boot"). The VM is then left running but
# half-configured, and a plain retry `up` sees state=running and silently
# skips boot-wait + guest network configuration — the create "succeeds" but
# the guest never gets its static host-only IP and the provision phase later
# dies UNREACHABLE (#211, pqc-full web1 2026-07-06). If a failed attempt
# already booted the VM, power it off first (VBoxManage — lock-free) so the
# retry re-runs the full boot + network-config sequence. Static IPs persist
# in the guest, so cycling a VM that did finish its config is safe.
create_vm() {
  local vm="$1"
  local log="${2:-$LOGDIR/$vm-create.log}"
  local t_start=$(date +%s)
  local attempt max_attempts=4   # 1 initial + 3 lock retries
  local log_ofs booted=0
  printf "  ${C_DIM}Creating${C_RESET} ${C_CYAN}%s${C_RESET}${C_DIM}...${C_RESET}" "$vm"
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    # Remember where this attempt's output starts — the log accumulates across
    # attempts, so the checks below must only look at the new portion.
    log_ofs=0
    [[ -f "$log" ]] && log_ofs=$(wc -c < "$log")
    if vagrant up "$vm" --no-provision >> "$log" 2>&1; then
      local t_elapsed=$(( $(date +%s) - t_start ))
      local t_m=$(( t_elapsed / 60 )) t_s=$(( t_elapsed % 60 ))
      printf "\r  ${C_GREEN}OK${C_RESET}    ${C_CYAN}%-12s${C_RESET} ${C_DIM}(%dm%02ds)${C_RESET}  [${C_DIM}%s${C_RESET}]\n" \
        "$vm" "$t_m" "$t_s" "$(elapsed_total)"
      return 0
    fi
    # Sticky across attempts: once any failed attempt has powered the VM on,
    # every subsequent lock retry must go through the power-off guard.
    tail -c +"$(( log_ofs + 1 ))" "$log" | grep -q "Booting VM" && booted=1
    if [[ $attempt -lt $max_attempts ]] && tail -c +"$(( log_ofs + 1 ))" "$log" | grep -q "requested machine because it is locked"; then
      printf "\r  ${C_YELLOW}LOCK${C_RESET}  ${C_CYAN}%-12s${C_RESET} ${C_DIM}transient machine lock — retry %d/%d in 10s${C_RESET}\n" \
        "$vm" "$attempt" "$(( max_attempts - 1 ))"
      sleep 10
      if (( booted )) && VBoxManage showvminfo "${LAB_VBOX_PREFIX}-${vm}" --machinereadable 2>/dev/null \
           | grep -q '^VMState="running"'; then
        printf "  ${C_YELLOW}CYCLE${C_RESET} ${C_CYAN}%-12s${C_RESET} ${C_DIM}create interrupted mid-boot — powering off so the retry redoes network config${C_RESET}\n" \
          "$vm"
        VBoxManage controlvm "${LAB_VBOX_PREFIX}-${vm}" poweroff >> "$log" 2>&1 || true
        sleep 3
      fi
      printf "  ${C_DIM}Creating${C_RESET} ${C_CYAN}%s${C_RESET}${C_DIM}... (retry %d/%d)${C_RESET}" \
        "$vm" "$attempt" "$(( max_attempts - 1 ))"
    else
      break
    fi
  done
  local t_elapsed=$(( $(date +%s) - t_start ))
  local t_m=$(( t_elapsed / 60 )) t_s=$(( t_elapsed % 60 ))
  printf "\r  ${C_RED}FAIL${C_RESET}  ${C_CYAN}%-12s${C_RESET} ${C_DIM}(%dm%02ds)${C_RESET}  (see %s)\n" \
    "$vm" "$t_m" "$t_s" "$log"
  return 1
}

# ── Rebuild mode: destroy + create + provision selected VMs ──────────────
if [[ -n "$REBUILD_VM" ]]; then
  IFS=',' read -ra REBUILD_LIST <<< "$REBUILD_VM"

  # Safety: refuse to rebuild dc1
  for vm in "${REBUILD_LIST[@]}"; do
    if [[ "$vm" == "dc1" ]]; then
      printf "  ${C_RED:-\033[31m}ERROR:${C_RESET:-\033[0m} Cannot rebuild dc1 — all other VMs depend on it.\n"
      printf "  To rebuild dc1, destroy and rebuild the entire lab.\n"
      exit 1
    fi
  done

  printf "\n${C_CYAN}═══ Rebuilding %d VM(s): %s ═══${C_RESET}\n\n" "${#REBUILD_LIST[@]}" "${REBUILD_LIST[*]}"

  # Phase 1: Destroy
  for vm in "${REBUILD_LIST[@]}"; do
    printf "  ${C_DIM}Destroying${C_RESET} ${C_CYAN}%s${C_RESET}${C_DIM}...${C_RESET}" "$vm"
    if _vagrant_retry_lock "$LOGDIR/$vm-rebuild.log" destroy -f "$vm"; then
      printf "\r  ${C_GREEN}OK${C_RESET}    ${C_CYAN}%-12s${C_RESET} ${C_DIM}destroyed${C_RESET}\n" "$vm"
    else
      printf "\r  ${C_RED}FAIL${C_RESET}  ${C_CYAN}%-12s${C_RESET} ${C_DIM}destroy failed (see $LOGDIR/$vm-rebuild.log)${C_RESET}\n" "$vm"
      exit 1
    fi
  done
  echo ""

  # Phase 2: Create (sequential — holds lock). create_vm brings the lock
  # retry + mid-boot power-cycle guard that the plain `vagrant up` here
  # lacked (#211).
  printf "  ${C_DIM}Creating VMs...${C_RESET}\n"
  for vm in "${REBUILD_LIST[@]}"; do
    create_vm "$vm" "$LOGDIR/$vm-rebuild.log" || exit 1
  done
  echo ""

  # Phase 3: Provision (parallel)
  printf "  ${C_DIM}Provisioning...${C_RESET}\n"
  declare -A RB_PIDS RB_START
  for vm in "${REBUILD_LIST[@]}"; do
    RB_START[$vm]=$(date +%s)
    printf "  ${C_DIM}Provisioning${C_RESET} ${C_CYAN}%s${C_RESET} ${C_DIM}(log: $LOGDIR/$vm-rebuild.log)${C_RESET}\n" "$vm"
    (_vagrant_retry_lock "$LOGDIR/$vm-rebuild.log" provision "$vm") &
    RB_PIDS[$vm]=$!
    write_pidfile "$vm" "${RB_PIDS[$vm]}"
  done

  # Wait for all
  RB_FAILURES=0
  for vm in "${REBUILD_LIST[@]}"; do
    wait "${RB_PIDS[$vm]}" 2>/dev/null
    rc=$?
    elapsed=$(( $(date +%s) - ${RB_START[$vm]} ))
    em=$(( elapsed / 60 )); es=$(( elapsed % 60 ))
    if [[ $rc -eq 0 ]]; then
      printf "  ${C_GREEN}OK${C_RESET}    ${C_CYAN}%-12s${C_RESET} ${C_DIM}(%dm %ds)${C_RESET}\n" "$vm" "$em" "$es"
    else
      printf "  ${C_RED}FAIL${C_RESET}  ${C_CYAN}%-12s${C_RESET} ${C_DIM}(%dm %ds — see $LOGDIR/$vm-rebuild.log)${C_RESET}\n" "$vm" "$em" "$es"
      RB_FAILURES=$((RB_FAILURES + 1))
    fi
  done

  echo ""
  if [[ $RB_FAILURES -gt 0 ]]; then
    printf "  ${C_RED}%d VM(s) failed rebuild.${C_RESET} Logs: $LOGDIR/\n" "$RB_FAILURES"
    exit 1
  else
    printf "  ${C_GREEN}Rebuild complete.${C_RESET}\n"
    echo ""
    echo "Validate:"
    echo "  bash scripts/validate.sh ${REBUILD_LIST[*]}"
  fi
  exit 0
fi

# ── Tracking arrays ──────────────────────────────────────────────────────
declare -A VM_PIDS      # vm name -> PID
declare -A VM_START     # vm name -> epoch start time
declare -A VM_END       # vm name -> epoch end time
declare -A VM_STATUS    # vm name -> exit code
declare -A CREATE_FAILED # vm name -> 1 when the Phase-1 create failed
VM_ORDER=()             # ordered list of vm names

# Provision a VM in the background with logging and PID tracking.
launch_vm() {
  local vm="$1"
  VM_START[$vm]="$(date +%s)"
  VM_ORDER+=("$vm")
  printf "[${C_DIM}%s${C_RESET}] [${C_DIM}%s${C_RESET}] Provisioning ${C_CYAN}%s${C_RESET} (log: $LOGDIR/$vm.log)\n" \
    "$(date '+%H:%M:%S')" "$(elapsed_total)" "$vm"
  (_vagrant_retry_lock "$LOGDIR/$vm.log" provision "$vm") &
  VM_PIDS[$vm]=$!
  write_pidfile "$vm" "${VM_PIDS[$vm]}"
}

# Restore a VM from snapshot in the background
restore_vm() {
  local vm="$1"
  VM_START[$vm]="$(date +%s)"
  VM_ORDER+=("$vm")
  printf "[${C_DIM}%s${C_RESET}] [${C_DIM}%s${C_RESET}] Restoring ${C_CYAN}%s${C_RESET} from snapshot (log: $LOGDIR/$vm.log)\n" \
    "$(date '+%H:%M:%S')" "$(elapsed_total)" "$vm"
  (_vagrant_retry_lock "$LOGDIR/$vm.log" snapshot restore "$vm" baseline --no-provision) &
  VM_PIDS[$vm]=$!
  write_pidfile "$vm" "${VM_PIDS[$vm]}"
}

# Get current task name from a VM's log file
get_current_task() {
  local logfile="$1"
  [[ -f "$logfile" ]] || return
  grep -oP '(?<=TASK \[)[^\]]+' "$logfile" | tail -1
}

# Get last task result (ok/changed/skipping/fatal) with color
get_last_result() {
  local logfile="$1"
  [[ -f "$logfile" ]] || return
  local last
  last="$(grep -oP '(ok|changed|skipping|fatal|included|failed)(?=:)' "$logfile" | tail -1)"
  case "$last" in
    ok)       printf "${C_GREEN}ok${C_RESET}" ;;
    changed)  printf "${C_YELLOW}changed${C_RESET}" ;;
    skipping) printf "${C_DIM}skip${C_RESET}" ;;
    included) printf "${C_DIM}incl${C_RESET}" ;;
    fatal|failed) printf "${C_RED}FAILED${C_RESET}" ;;
    *)        printf "${C_DIM}...${C_RESET}" ;;
  esac
}

# Print status for all running VMs
print_vm_status() {
  local line=""
  for vm in "${VM_ORDER[@]}"; do
    [[ "$vm" == "dc1" ]] && continue
    [[ -z "${VM_PIDS[$vm]:-}" ]] && continue
    [[ -n "${VM_DONE[$vm]:-}" ]] && continue
    task="$(get_current_task "$LOGDIR/$vm.log")"
    task="${task:-starting...}"
    result="$(get_last_result "$LOGDIR/$vm.log")"
    c="${VM_COLOR[$vm]}"
    elapsed=$(( $(date +%s) - ${VM_START[$vm]} ))
    em=$(( elapsed / 60 )); es=$(( elapsed % 60 ))
    line+="  ${c}${vm}${C_RESET} ${C_DIM}${em}m${es}s${C_RESET} ${task} [${result}]\n"
  done
  if [[ -n "$line" ]]; then
    printf "\n  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}\n" "$(date '+%H:%M:%S')" "$(elapsed_total)"
    printf "$line"
  fi
}

# Hang-detection threshold (seconds of log inactivity after a fatal marker
# before we declare the VM stuck and stop waiting on its PID). Without it,
# up.sh can wait hours on a VM whose Ansible playbook crashed at
# `Ansible failed to complete successfully` while the vagrant subprocess hangs
# internally. Default: 600s = 10 min. Override via LAB_HANG_DETECT_SEC env
# var. Set to 0 to disable.
LAB_HANG_DETECT_SEC="${LAB_HANG_DETECT_SEC:-600}"

# Return 0 if the VM's log shows a fatal-finish marker (Ansible has reported
# failure but vagrant may still be running). Caller still needs the inactivity
# window check before declaring hung.
log_shows_fatal_finish() {
  local logfile="$1"
  [[ -f "$logfile" ]] || return 1
  # Vagrant emits this exact line when the Ansible provisioner exits non-zero.
  # Also accept a PLAY RECAP that includes a non-zero failed= count.
  grep -qE 'Ansible failed to complete successfully|PLAY RECAP.*failed=[1-9]' "$logfile"
}

# Return 0 if the VM's log hasn't been written to in $1 seconds.
log_idle_for() {
  local logfile="$1" threshold="$2"
  [[ -f "$logfile" ]] || return 1
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -c %Y "$logfile" 2>/dev/null || stat -f %m "$logfile" 2>/dev/null)"
  [[ -z "$mtime" ]] && return 1
  (( now - mtime >= threshold ))
}

# Check for any VMs that finished and print their result
check_finished_vms() {
  for vm in "${VM_ORDER[@]}"; do
    [[ "$vm" == "dc1" ]] && continue
    [[ -z "${VM_PIDS[$vm]:-}" ]] && continue
    [[ -n "${VM_DONE[$vm]:-}" ]] && continue

    pid="${VM_PIDS[$vm]}"
    local pid_alive=0
    kill -0 "$pid" 2>/dev/null && pid_alive=1

    local marked_done=0
    local hung=0

    if (( pid_alive == 0 )); then
      # Normal path: subprocess exited cleanly (success or non-zero).
      wait "$pid" 2>/dev/null
      VM_STATUS[$vm]=$?
      marked_done=1
    elif (( LAB_HANG_DETECT_SEC > 0 )) \
         && log_shows_fatal_finish "$LOGDIR/$vm.log" \
         && log_idle_for "$LOGDIR/$vm.log" "$LAB_HANG_DETECT_SEC"; then
      # Hang path: Ansible already declared failure AND the log has been
      # silent for the detect window — the vagrant subprocess is stuck
      # (saw this on scanner1 round 3 / 2026-05-22, ~3-hour stall). Kill
      # the subshell tree so we stop waiting; surface as a special status
      # so the operator knows we forced it.
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      VM_STATUS[$vm]=137   # 128 + SIGKILL — distinct from a clean Ansible exit
      marked_done=1
      hung=1
    fi

    if (( marked_done )); then
      VM_END[$vm]="$(date +%s)"
      VM_DONE[$vm]=1
      elapsed=$(( ${VM_END[$vm]} - ${VM_START[$vm]} ))
      em=$(( elapsed / 60 )); es=$(( elapsed % 60 ))
      c="${VM_COLOR[$vm]}"
      if (( hung )); then
        printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${c}%-10s${C_RESET} ${C_RED}✗ HUNG${C_RESET} ${C_DIM}(killed after %ds log-idle post-fail, %dm %ds total)${C_RESET}\n" \
          "$(date '+%H:%M:%S')" "$(elapsed_total)" "$vm" "$LAB_HANG_DETECT_SEC" "$em" "$es"
      elif [[ ${VM_STATUS[$vm]} -eq 0 ]]; then
        printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${c}%-10s${C_RESET} ${C_GREEN}✓ done${C_RESET} ${C_DIM}(%dm %ds)${C_RESET}\n" \
          "$(date '+%H:%M:%S')" "$(elapsed_total)" "$vm" "$em" "$es"
        should_save "$vm" && save_snap "$vm"
      else
        printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${c}%-10s${C_RESET} ${C_RED}✗ FAILED${C_RESET} ${C_DIM}(exit %d, %dm %ds)${C_RESET}\n" \
          "$(date '+%H:%M:%S')" "$(elapsed_total)" "$vm" "${VM_STATUS[$vm]}" "$em" "$es"
      fi
    fi
  done
}

# Sleep with monitoring — polls every POLL seconds during a longer wait.
# If last_vm is provided, breaks early when that VM finishes.
monitor_sleep() {
  local total="$1"
  local last_vm="${2:-}"
  local waited=0
  while (( waited < total )); do
    local chunk="$POLL"
    (( waited + chunk > total )) && chunk=$(( total - waited ))
    sleep "$chunk"
    waited=$(( waited + chunk ))
    check_finished_vms
    # Break early if the just-launched VM already finished
    if [[ -n "$last_vm" && -n "${VM_DONE[$last_vm]:-}" ]]; then
      return
    fi
    print_vm_status
  done
}

POLL_INTERVAL="$POLL"
declare -A VM_DONE  # vm -> 1 when finished

# ── Build VM list ─────────────────────────────────────────────────────────
# DC1 provisions sequentially (phase 2) when present in the active profile.
# Remaining VMs provision in parallel (phase 3).
# --file overrides everything with a custom list.
# --all is now equivalent to LAB_PROFILE=full (kept as alias for backward compat).

if $ALL; then
  # Reload helper with LAB_PROFILE=full so COMPONENTS expands to everything.
  # `LAB_PROFILE=full source ...` only feeds the var into the source call —
  # it does NOT persist in the parent shell, so child `vagrant up/provision`
  # processes wouldn't see ENV['LAB_PROFILE'] and the Vagrantfile resolver
  # silently falls back to `core` (4 VMs). Running `LAB_PROFILE=full bash up.sh`
  # sets the var on the bash invocation itself and works, but `bash up.sh --all`
  # does not — without the export below it ends in "machine not found" failures.
  # Export here so every downstream vagrant call sees the resolved profile.
  export LAB_PROFILE=full
  source "$(dirname "$0")/scripts/lib/profile-helper.sh"
  TOPOLOGY="$LAB_PROFILE_NAME"
  echo "Profile (--all): $LAB_PROFILE_NAME (${#LAB_PROFILE_COMPONENTS_ARR[@]} VMs)"
fi

# Preferred parallel-launch order for known VMs. Anything in the profile but
# not listed here gets appended in profile order.
PREFERRED_PARALLEL_ORDER=(
  manage1 web1 ca1 rootca issueca
  dc2 tomcat1 client1 wsus1
  observe1 ejbca1 stepca1 hydra1 acme1 scanner1
)

if [[ -n "$VM_FILE" ]]; then
  if [[ ! -f "$VM_FILE" ]]; then
    echo "ERROR: VM file not found: $VM_FILE"
    exit 1
  fi
  PARALLEL_VMS=()
  while IFS= read -r line; do
    line="${line%%#*}"          # strip comments
    line="$(echo "$line" | xargs)"  # trim whitespace
    [[ -z "$line" ]] && continue
    [[ "$line" == "dc1" ]] && continue  # dc1 always runs sequentially
    PARALLEL_VMS+=("$line")
  done < "$VM_FILE"
  BUILD_MODE="custom (--file $VM_FILE)"
else
  # Build PARALLEL_VMS = (active profile components) - dc1, in preferred order.
  declare -A _in_profile=()
  for vm in "${LAB_PROFILE_COMPONENTS_ARR[@]}"; do _in_profile[$vm]=1; done

  PARALLEL_VMS=()
  declare -A _added=()
  for vm in "${PREFERRED_PARALLEL_ORDER[@]}"; do
    [[ "$vm" == "dc1" ]] && continue
    [[ -n "${_in_profile[$vm]:-}" && -z "${_added[$vm]:-}" ]] || continue
    PARALLEL_VMS+=("$vm")
    _added[$vm]=1
  done
  # Append any profile components not in the preferred-order table.
  for vm in "${LAB_PROFILE_COMPONENTS_ARR[@]}"; do
    [[ "$vm" == "dc1" ]] && continue
    [[ -n "${_added[$vm]:-}" ]] && continue
    PARALLEL_VMS+=("$vm")
    _added[$vm]=1
  done
  unset _in_profile _added

  BUILD_MODE="profile: $LAB_PROFILE_NAME (${#LAB_PROFILE_COMPONENTS_ARR[@]} VMs)"
fi

# Check if manage1 is in the VM list for pre-launch (overlaps with DC1 build)
MANAGE1_PRELAUNCH=false
for vm in "${PARALLEL_VMS[@]}"; do
  [[ "$vm" == "manage1" ]] && MANAGE1_PRELAUNCH=true
done

DC1_IN_PROFILE=false
profile_has dc1 && DC1_IN_PROFILE=true

echo ""
printf "${C_CYAN}═══ Build plan: $BUILD_MODE ═══${C_RESET}\n"
echo "  Phase 1: Create all VMs sequentially (no lock contention)"
if $DC1_IN_PROFILE; then
  if should_restore dc1; then
    echo "  Phase 2: DC1 restore from snapshot"
  elif [[ "${LAB_PHASE2_OVERLAP:-true}" == "true" ]]; then
    echo "  Phase 2: Provision DC1 (overlapped with Phase 1 — set LAB_PHASE2_OVERLAP=false to disable)"
  else
    echo "  Phase 2: Provision DC1 (sequential)"
  fi
else
  echo "  Phase 2: ${C_DIM}skipped (dc1 not in profile)${C_RESET}"
fi
printf "  Phase 3: Provision in parallel:  "
first=true
for vm in "${PARALLEL_VMS[@]}"; do
  $first || printf ", "
  first=false
  if should_restore "$vm"; then
    printf "%s${C_DIM}(snap)${C_RESET}" "$vm"
  else
    printf "%s" "$vm"
  fi
done
echo ""
echo "  poll: ${POLL}s"
echo ""

# ── RAM preflight (2026-07-02 dual-lab OOM incident) ──────────────────────
# Running VBox VMs commit their full configured RAM as guests boot, so a
# second big lab on the same host swap-thrashes it until systemd-oomd kills
# a build mid-provision (full + pqc-full price at ~128 GiB on a 125 GiB
# host). Price this launch before Phase 1: committed (running VBox VMs, any
# lab) + incoming (profile VMs not yet running) must fit in MemTotal minus a
# host reserve (10%, 8 GiB floor). lib/ram_budget.rb does the math.
#   LAB_RAM_GUARD=off      skip the check entirely
#   LAB_RAM_GUARD=warn     report a breach but continue
#   LAB_RAM_RESERVE_MB=N   override the host reserve
# The check fails open: if it errors (no VBoxManage, parse trouble), the
# build proceeds — it must never be the thing that blocks a build.
if [[ "${LAB_RAM_GUARD:-on}" != "off" ]]; then
  _guard_vms=""
  $DC1_IN_PROFILE && _guard_vms="dc1"
  for vm in "${PARALLEL_VMS[@]}"; do _guard_vms+="${_guard_vms:+,}$vm"; done
  ruby -I "$(dirname "$0")/lib" -r ram_budget -e 'exit RamBudget.cli(ARGV)' -- \
    --vms "$_guard_vms" --prefix "$LAB_VBOX_PREFIX" \
    ${LAB_RAM_RESERVE_MB:+--reserve-mb "$LAB_RAM_RESERVE_MB"}
  _guard_rc=$?
  if [[ $_guard_rc -eq 2 ]]; then
    if [[ "${LAB_RAM_GUARD:-on}" == "warn" ]]; then
      printf "  ${C_YELLOW}LAB_RAM_GUARD=warn — proceeding despite the RAM breach.${C_RESET}\n"
    else
      printf "  ${C_RED}Aborting before Phase 1 (RAM preflight).${C_RESET}\n"
      exit 1
    fi
  fi
  unset _guard_vms _guard_rc
  echo ""
fi

# Assign colors to all VMs
$DC1_IN_PROFILE && assign_color dc1
for vm in "${PARALLEL_VMS[@]}"; do
  assign_color "$vm"
done

# ── Phase 1: Create all VMs sequentially (no lock contention) ─────────────
# Each create takes ~30-60s. No provisioning — just box import + VM setup.
# VMs start booting immediately after creation.
CREATE_VMS=()
RESTORE_VMS=()

if $DC1_IN_PROFILE; then
  if ! should_restore dc1; then
    CREATE_VMS+=(dc1)
  else
    RESTORE_VMS+=(dc1)
  fi
fi

for vm in "${PARALLEL_VMS[@]}"; do
  if should_restore "$vm"; then
    RESTORE_VMS+=("$vm")
  else
    CREATE_VMS+=("$vm")
  fi
done

# Phase 2 overlap (2026-05-22 perf): start dc1's Ansible provision in the
# background as soon as dc1's VM is created, so it runs in parallel with the
# remaining Phase 1 creates. Phase 2 below just waits for the background PID
# instead of running the provision serially. Saves ~15 min on full / two-tier
# / one-tier where Phase 1 (~57 min) dwarfs Phase 2 (~15 min).
# Disabled if: dc1 not in profile / restored from snapshot / already promoted
# / dc1's create failed.
DC1_OVERLAP_PID=""
DC1_OVERLAP=false
DC1_ALREADY_READY=false
if $DC1_IN_PROFILE && ! should_restore dc1; then
  dc1_ip=$(grep '^dc1 ' "$ANSIBLE_DIR/inventory/$LAB_PROFILE_NAME/static.ini" 2>/dev/null | grep -oP 'ansible_host=\K\S+')
  if [[ -n "$dc1_ip" ]] && vagrant winrm -c "nltest /dsgetdc:${LAB_DOMAIN}" dc1 >/dev/null 2>&1; then
    DC1_ALREADY_READY=true
  fi
  if ! $DC1_ALREADY_READY && [[ "${LAB_PHASE2_OVERLAP:-true}" == "true" ]]; then
    DC1_OVERLAP=true
  fi
fi

if [[ ${#CREATE_VMS[@]} -gt 0 ]]; then
  printf "\n${C_CYAN}═══ Creating %d VMs (sequential, no-provision) ═══${C_RESET}\n\n" "${#CREATE_VMS[@]}"
  for vm in "${CREATE_VMS[@]}"; do
    create_vm "$vm" || CREATE_FAILED[$vm]=1
    # Phase 2 overlap: kick off dc1's provision in background right after its
    # create so it can run alongside the remaining Phase 1 creates. Skipped
    # when the create failed — provisioning a half-created VM (host-only NIC
    # never configured) just produces a misleading Ansible UNREACHABLE.
    if $DC1_OVERLAP && [[ "$vm" == "dc1" && -z "${CREATE_FAILED[dc1]:-}" && -z "$DC1_OVERLAP_PID" ]]; then
      VM_START[dc1]="$(date +%s)"
      : > "$LOGDIR/dc1.log"
      (_vagrant_retry_lock "$LOGDIR/dc1.log" provision dc1) &
      DC1_OVERLAP_PID=$!
      write_pidfile "dc1" "$DC1_OVERLAP_PID"
      printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${C_CYAN}dc1${C_RESET} ${C_DIM}provision started in background (PID %s, log: $LOGDIR/dc1.log)${C_RESET}\n" \
        "$(date '+%H:%M:%S')" "$(elapsed_total)" "$DC1_OVERLAP_PID"
    fi
  done
  echo ""
fi

if [[ ${#RESTORE_VMS[@]} -gt 0 ]]; then
  printf "${C_CYAN}═══ Restoring %d VMs from snapshot ═══${C_RESET}\n\n" "${#RESTORE_VMS[@]}"
  for vm in "${RESTORE_VMS[@]}"; do
    printf "  ${C_DIM}Restoring${C_RESET} ${C_CYAN}%s${C_RESET}${C_DIM}...${C_RESET}" "$vm"
    if _vagrant_retry_lock "$LOGDIR/$vm-snap.log" snapshot restore "$vm" baseline --no-provision; then
      printf "\r  ${C_GREEN}OK${C_RESET}    ${C_CYAN}%-12s${C_RESET}\n" "$vm"
    else
      printf "\r  ${C_RED}FAIL${C_RESET}  ${C_CYAN}%-12s${C_RESET} (see $LOGDIR/$vm-snap.log)\n" "$vm"
    fi
  done
  echo ""
fi

# ── Phase 2: Provision DC1 sequentially (AD DS must be up first) ──────────
# Skipped entirely when dc1 is not in the active profile.
# With Phase 2 overlap (default on), this just waits for the background PID
# kicked off during Phase 1.
set -o pipefail

if $DC1_IN_PROFILE; then
  if [[ -z "${VM_START[dc1]:-}" ]]; then
    VM_START[dc1]="$(date +%s)"
  fi
  VM_ORDER+=(dc1)

  if [[ -n "${CREATE_FAILED[dc1]:-}" ]]; then
    # Create failed in Phase 1 (even after the lock retry) — a provision can
    # only fail against a VM that never finished network config, so fail fast
    # and point at the create log instead of a misleading UNREACHABLE.
    VM_STATUS[dc1]=1
    printf "${C_RED}═══ DC1 create failed — skipping provision ═══${C_RESET}\n\n"
  elif should_restore dc1; then
    # DC1 already restored above — just record success
    VM_STATUS[dc1]=0
  elif $DC1_ALREADY_READY; then
    # DC1 already provisioned and AD DS is serving — skip phase 2
    VM_STATUS[dc1]=0
    printf "${C_CYAN}═══ DC1 already provisioned (AD DS responding) — skipping ═══${C_RESET}\n\n"
  elif [[ -n "$DC1_OVERLAP_PID" ]]; then
    # Phase 2 overlap: dc1 provision started during Phase 1 — wait for it.
    printf "${C_CYAN}═══ Waiting for DC1 provision (overlap with Phase 1) ═══${C_RESET}\n\n"
    printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${C_CYAN}dc1${C_RESET} ${C_DIM}waiting on background PID %s...${C_RESET}\n" \
      "$(date '+%H:%M:%S')" "$(elapsed_total)" "$DC1_OVERLAP_PID"
    if wait "$DC1_OVERLAP_PID"; then
      VM_STATUS[dc1]=0
      printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${C_CYAN}dc1${C_RESET} ${C_GREEN}✓ background provision finished${C_RESET}\n" \
        "$(date '+%H:%M:%S')" "$(elapsed_total)"
    else
      VM_STATUS[dc1]=$?
    fi
  else
    printf "${C_CYAN}═══ Provisioning DC1 (sequential) ═══${C_RESET}\n\n"
    if vagrant provision dc1 2>&1 | tee "$LOGDIR/dc1.log" | awk '
      /^ok: /       {printf "\033[32m%s\033[0m\n",$0;next}
      /^changed: /  {printf "\033[33m%s\033[0m\n",$0;next}
      /^skipping: / {printf "\033[34m%s\033[0m\n",$0;next}
      /^(fatal|failed): / {printf "\033[31m%s\033[0m\n",$0;next}
      NR%2==0       {printf "\033[38;5;242m%s\033[0m\n",$0;next}
      1'; then
      VM_STATUS[dc1]=0
    else
      VM_STATUS[dc1]=$?
    fi
  fi

  if [[ ${VM_STATUS[dc1]} -eq 0 ]]; then
    VM_END[dc1]="$(date +%s)"
    elapsed=$(( ${VM_END[dc1]} - ${VM_START[dc1]} ))
    em=$(( elapsed / 60 )); es=$(( elapsed % 60 ))
    echo ""
    printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${C_CYAN}dc1${C_RESET} ${C_GREEN}✓ done${C_RESET} ${C_DIM}(%dm %ds)${C_RESET}\n" \
      "$(date '+%H:%M:%S')" "$(elapsed_total)" "$em" "$es"
    should_save dc1 && save_snap dc1
    echo ""
  else
    dc1_fail_log="$LOGDIR/dc1.log"
    [[ -n "${CREATE_FAILED[dc1]:-}" ]] && dc1_fail_log="$LOGDIR/dc1-create.log"
    echo ""
    printf "  ${C_RED}FATAL:${C_RESET} DC1 failed — cannot continue (see %s)\n" "$dc1_fail_log"
    exit 1
  fi
fi

# ── Phase 3: Provision all remaining VMs in parallel ──────────────────────
# No lock contention — VMs already created/restored. Retry loops handle
# dependencies (machine_cert waits for CA1, domain_join waits for DC1, etc.)
#
# CA-VM domain-join stagger: when ca1/rootca/issueca
# launch fully in parallel, they hit dc1's WMI / AD layer with concurrent
# machine-account creates ~4-5 min into their playbooks (right after the heavy
# ADCS feature install bursts). Symptom: `microsoft.ad.membership` returns
# WS-Management InvalidSelectors HTTP 500. The race rotates between CA VMs
# round-to-round. Adding LAB_CA_LAUNCH_STAGGER_SEC seconds between consecutive
# CA-VM launches in Phase 3 gives each VM's domain_join window enough
# separation that the race doesn't fire. Default 60s. Disable with =0.
LAB_CA_LAUNCH_STAGGER_SEC="${LAB_CA_LAUNCH_STAGGER_SEC:-60}"
_is_ca_vm() {
  case "$1" in
    ca1|rootca|issueca) return 0 ;;
    *) return 1 ;;
  esac
}

printf "${C_CYAN}═══ Provisioning %d VMs in parallel ═══${C_RESET}\n\n" "${#PARALLEL_VMS[@]}"

_prev_was_ca=false
for vm in "${PARALLEL_VMS[@]}"; do
  if should_restore "$vm"; then
    # Already restored in phase 1 — record as done
    VM_START[$vm]="$(date +%s)"
    VM_ORDER+=("$vm")
    VM_STATUS[$vm]=0
    VM_END[$vm]="$(date +%s)"
    VM_DONE[$vm]=1
    printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${C_CYAN}%-10s${C_RESET} ${C_GREEN}✓ restored${C_RESET}\n" \
      "$(date '+%H:%M:%S')" "$(elapsed_total)" "$vm"
    should_save "$vm" && save_snap "$vm"
    _prev_was_ca=false
  else
    # If we're about to launch a CA VM AND the previous launched VM was also a CA,
    # sleep to stagger their domain_join windows.
    if _is_ca_vm "$vm" && $_prev_was_ca && [[ "$LAB_CA_LAUNCH_STAGGER_SEC" -gt 0 ]]; then
      printf "  ${C_DIM}%s${C_RESET} ${C_DIM}[%s]${C_RESET}  ${C_DIM}staggering ${LAB_CA_LAUNCH_STAGGER_SEC}s before launching next CA VM (avoids domain_join WMI race)${C_RESET}\n" \
        "$(date '+%H:%M:%S')" "$(elapsed_total)"
      sleep "$LAB_CA_LAUNCH_STAGGER_SEC"
    fi
    launch_vm "$vm"
    if _is_ca_vm "$vm"; then
      _prev_was_ca=true
    else
      _prev_was_ca=false
    fi
  fi
done

# ── Wait for remaining background VMs ──────────────────────────────────
while true; do
  check_finished_vms
  # Check if all background VMs are done
  all_done=true
  for vm in "${VM_ORDER[@]}"; do
    [[ "$vm" == "dc1" ]] && continue
    [[ -z "${VM_DONE[$vm]:-}" ]] && all_done=false
  done
  $all_done && break
  print_vm_status
  sleep "$POLL_INTERVAL"
done

# Deduplicate VM_ORDER (preserves first occurrence order)
declare -A _seen
UNIQUE_VMS=()
for vm in "${VM_ORDER[@]}"; do
  [[ -n "${_seen[$vm]:-}" ]] && continue
  _seen[$vm]=1
  UNIQUE_VMS+=("$vm")
done

# Count failures
FAILURES=0
for vm in "${UNIQUE_VMS[@]}"; do
  [[ "$vm" == "dc1" ]] && continue
  [[ ${VM_STATUS[$vm]} -ne 0 ]] && FAILURES=$((FAILURES + 1))
done

# ── Summary ─────────────────────────────────────────────────────────────
BUILD_ELAPSED=$(( $(date +%s) - BUILD_START ))
BUILD_MIN=$(( BUILD_ELAPSED / 60 ))
BUILD_SEC=$(( BUILD_ELAPSED % 60 ))

echo ""
printf "  ${C_DIM}═══════════════════════════════════════════════════════${C_RESET}\n"
printf "  ${C_CYAN} BUILD SUMMARY${C_RESET}  ${C_DIM}(${BUILD_MIN}m ${BUILD_SEC}s total)${C_RESET}\n"
printf "  ${C_DIM}═══════════════════════════════════════════════════════${C_RESET}\n"
printf "  ${C_DIM}%-12s %-8s %s${C_RESET}\n" "VM" "STATUS" "TIME"
printf "  ${C_DIM}%-12s %-8s %s${C_RESET}\n" "──────────" "──────" "────"
for vm in "${UNIQUE_VMS[@]}"; do
  c="${VM_COLOR[$vm]:-$C_WHITE}"
  if [[ ${VM_STATUS[$vm]} -eq 0 ]]; then
    status="${C_GREEN}OK${C_RESET}"
  else
    status="${C_RED}FAIL${C_RESET}"
  fi
  end="${VM_END[$vm]:-$(date +%s)}"
  elapsed=$(( end - ${VM_START[$vm]} ))
  em=$(( elapsed / 60 )); es=$(( elapsed % 60 ))
  printf "  ${c}%-12s${C_RESET} %-8b ${C_DIM}%dm %ds${C_RESET}\n" "$vm" "$status" "$em" "$es"
done
printf "  ${C_DIM}═══════════════════════════════════════════════════════${C_RESET}\n"

if [[ $FAILURES -gt 0 ]]; then
  echo ""
  echo "$FAILURES VM(s) failed. Logs: $LOGDIR/"
  echo ""
  echo "Re-provision failed VMs:"
  for vm in "${UNIQUE_VMS[@]}"; do
    if [[ ${VM_STATUS[$vm]} -ne 0 ]]; then
      echo "  vagrant provision $vm"
    fi
  done
  echo ""
  exit 1
fi

if ! $ALL; then
  # Show VMs in the master inventory that aren't in the active profile.
  declare -A _have=()
  for vm in "${LAB_PROFILE_COMPONENTS_ARR[@]}"; do _have[$vm]=1; done
  MISSING=()
  for vm in dc2 client1 tomcat1 wsus1 ejbca1 stepca1 hydra1 observe1 acme1 scanner1; do
    [[ -z "${_have[$vm]:-}" ]] && MISSING+=("$vm")
  done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo "Other VMs available in the master inventory (not in '$LAB_PROFILE_NAME'):"
    for vm in "${MISSING[@]}"; do
      echo "  LAB_COMPONENTS=${LAB_PROFILE_COMPONENTS//,/+},$vm $0   # add $vm"
    done
    echo "  $0 --list-profiles   # try a different profile"
  fi
fi

if profile_has ejbca1 && profile_has dc1; then
  echo ""
  echo "After EJBCA1 is up, publish trust to AD:"
  echo "  vagrant provision dc1 --provision-with ejbca-trust"
fi
echo ""
echo "Validate build health:"
echo "  bash scripts/validate.sh"
