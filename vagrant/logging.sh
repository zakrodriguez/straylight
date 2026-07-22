#!/bin/bash
# Enable, disable, or check status of logging services across the lab.
# Services: winlogbeat + sysmon (Windows), filebeat (Linux + WEB1).

set -euo pipefail

# ── ANSI Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

# Resolve active profile (sets LAB_PROFILE_NAME, VAGRANT_DOTFILE_PATH).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRIPT_DIR/scripts/lib/profile-helper.sh"

# ── VM Definitions ───────────────────────────────────────────────────────
# Derived from topology.yml via vm-registry.sh — the single source of truth.
# The previous hardcoded lists omitted scanner1/acme1/apps1
# (Linux) and rootca-pqc/issueca-pqc/sqlhost1 (Windows).
source "$_SCRIPT_DIR/scripts/lib/vm-registry.sh"
mapfile -t WINDOWS_VMS < <(vm_windows)
mapfile -t LINUX_VMS < <(vm_linux)
ALL_VMS=("${WINDOWS_VMS[@]}" "${LINUX_VMS[@]}")

# Services per VM type
# Windows default: winlogbeat sysmon
# Linux default:   filebeat
# WEB1 special:    winlogbeat sysmon filebeat

get_services() {
  local vm="$1"
  case "$vm" in
    web1)
      echo "winlogbeat sysmon filebeat"
      ;;
    *)
      if is_linux_vm "$vm"; then
        echo "filebeat"
      else
        echo "winlogbeat sysmon"
      fi
      ;;
  esac
}

is_windows_vm() {
  local vm="$1"
  for w in "${WINDOWS_VMS[@]}"; do
    [[ "$w" == "$vm" ]] && return 0
  done
  return 1
}

is_linux_vm() {
  local vm="$1"
  for l in "${LINUX_VMS[@]}"; do
    [[ "$l" == "$vm" ]] && return 0
  done
  return 1
}

# Map service name to Windows service name
win_service_name() {
  local svc="$1"
  case "$svc" in
    winlogbeat) echo "winlogbeat" ;;
    sysmon)     echo "Sysmon64" ;;
    filebeat)   echo "filebeat" ;;
    *)          echo "$svc" ;;
  esac
}

# ── VM State Helpers ─────────────────────────────────────────────────────
is_vm_running() {
  local vm="$1"
  vagrant status "$vm" --machine-readable 2>/dev/null | grep -q "state,running"
}

is_valid_vm() {
  local vm="$1"
  for v in "${ALL_VMS[@]}"; do
    [[ "$v" == "$vm" ]] && return 0
  done
  return 1
}

vm_has_service() {
  local vm="$1" svc="$2"
  local services
  services="$(get_services "$vm")"
  [[ " $services " == *" $svc "* ]]
}

# ── Service Control ──────────────────────────────────────────────────────
control_service() {
  local vm="$1" svc="$2" action="$3"  # action: start|stop
  local win_svc

  if is_windows_vm "$vm"; then
    win_svc="$(win_service_name "$svc")"
    if [[ "$action" == "start" ]]; then
      vagrant winrm -c "Start-Service -Name '$win_svc' -ErrorAction SilentlyContinue" "$vm" 2>/dev/null
    else
      vagrant winrm -c "Stop-Service -Name '$win_svc' -Force -ErrorAction SilentlyContinue" "$vm" 2>/dev/null
    fi
  elif is_linux_vm "$vm"; then
    vagrant ssh "$vm" -c "sudo systemctl $action $svc" 2>/dev/null
  fi
}

get_service_status() {
  local vm="$1" svc="$2"
  local win_svc result

  if is_windows_vm "$vm"; then
    win_svc="$(win_service_name "$svc")"
    result="$(vagrant winrm -c "(Get-Service -Name '$win_svc' -ErrorAction SilentlyContinue).Status" "$vm" 2>/dev/null)" || true
    # Trim whitespace
    result="$(echo "$result" | tr -d '[:space:]')"
    if [[ "$result" == "Running" ]]; then
      echo "running"
    elif [[ "$result" == "Stopped" ]]; then
      echo "stopped"
    elif [[ -z "$result" ]]; then
      echo "not-installed"
    else
      echo "unknown"
    fi
  elif is_linux_vm "$vm"; then
    result="$(vagrant ssh "$vm" -c "systemctl is-active $svc" 2>/dev/null)" || true
    result="$(echo "$result" | tr -d '[:space:]')"
    case "$result" in
      active)   echo "running" ;;
      inactive) echo "stopped" ;;
      failed)   echo "failed" ;;
      *)        echo "not-installed" ;;
    esac
  fi
}

# ── Actions ──────────────────────────────────────────────────────────────
do_enable_disable() {
  local action="$1" target="$2"
  local verb vm svc vms services

  if [[ "$action" == "enable" ]]; then
    verb="Starting"
  else
    verb="Stopping"
  fi

  # Parse target: "all", "vm", or "vm:service"
  if [[ "$target" == "all" ]]; then
    vms=("${ALL_VMS[@]}")
    for vm in "${vms[@]}"; do
      if ! is_vm_running "$vm"; then
        echo -e "  ${YELLOW}$vm${NC} — not running, skipping"
        continue
      fi
      IFS=' ' read -ra services <<< "$(get_services "$vm")"
      for svc in "${services[@]}"; do
        echo -n "  $verb $svc on $vm... "
        if [[ "$action" == "enable" ]]; then
          control_service "$vm" "$svc" "start"
        else
          control_service "$vm" "$svc" "stop"
        fi
        echo "done"
      done
    done
  elif [[ "$target" == *":"* ]]; then
    vm="${target%%:*}"
    svc="${target##*:}"
    if ! is_valid_vm "$vm"; then
      echo "Error: unknown VM '$vm'" >&2
      exit 1
    fi
    if ! vm_has_service "$vm" "$svc"; then
      echo "Error: $vm does not have service '$svc'" >&2
      echo "  Available services for $vm: $(get_services "$vm")" >&2
      exit 1
    fi
    if ! is_vm_running "$vm"; then
      echo -e "  ${YELLOW}$vm${NC} — not running" >&2
      exit 1
    fi
    echo -n "  $verb $svc on $vm... "
    if [[ "$action" == "enable" ]]; then
      control_service "$vm" "$svc" "start"
    else
      control_service "$vm" "$svc" "stop"
    fi
    echo "done"
  else
    vm="$target"
    if ! is_valid_vm "$vm"; then
      echo "Error: unknown VM '$vm'" >&2
      exit 1
    fi
    if ! is_vm_running "$vm"; then
      echo -e "  ${YELLOW}$vm${NC} — not running" >&2
      exit 1
    fi
    IFS=' ' read -ra services <<< "$(get_services "$vm")"
    for svc in "${services[@]}"; do
      echo -n "  $verb $svc on $vm... "
      if [[ "$action" == "enable" ]]; then
        control_service "$vm" "$svc" "start"
      else
        control_service "$vm" "$svc" "stop"
      fi
      echo "done"
    done
  fi
}

do_status() {
  local vm svc status services color label

  echo ""
  echo -e "${BOLD}Logging Service Status${NC}  (profile: $LAB_PROFILE_NAME)"
  echo ""
  printf "  %-12s %-14s %-14s %-14s\n" "VM" "winlogbeat" "sysmon" "filebeat"
  printf "  %-12s %-14s %-14s %-14s\n" "──────────" "──────────" "──────────" "──────────"

  for vm in "${ALL_VMS[@]}"; do
    IFS=' ' read -ra services <<< "$(get_services "$vm")"

    if ! is_vm_running "$vm"; then
      # VM is off — show yellow dashes for all its services
      local col_wb="—" col_sm="—" col_fb="—"
      local cwb="${YELLOW}" csm="${YELLOW}" cfb="${YELLOW}"

      # Only show columns for services the VM actually has
      if ! vm_has_service "$vm" "winlogbeat"; then cwb="${NC}"; col_wb="—"; fi
      if ! vm_has_service "$vm" "sysmon"; then csm="${NC}"; col_sm="—"; fi
      if ! vm_has_service "$vm" "filebeat"; then cfb="${NC}"; col_fb="—"; fi

      printf "  ${YELLOW}%-12s${NC} ${cwb}%-14s${NC} ${csm}%-14s${NC} ${cfb}%-14s${NC}\n" \
        "$vm" "$col_wb" "$col_sm" "$col_fb"
      continue
    fi

    # VM is running — query each service
    local col_wb="—" col_sm="—" col_fb="—"
    local cwb="${NC}" csm="${NC}" cfb="${NC}"

    for svc in winlogbeat sysmon filebeat; do
      if vm_has_service "$vm" "$svc"; then
        status="$(get_service_status "$vm" "$svc")"
        case "$status" in
          running)       color="${GREEN}"; label="running" ;;
          stopped)       color="${RED}";   label="stopped" ;;
          failed)        color="${RED}";   label="failed" ;;
          not-installed) color="${NC}";    label="n/a" ;;
          *)             color="${NC}";    label="$status" ;;
        esac
      else
        color="${NC}"
        label="—"
      fi

      case "$svc" in
        winlogbeat) col_wb="$label"; cwb="$color" ;;
        sysmon)     col_sm="$label"; csm="$color" ;;
        filebeat)   col_fb="$label"; cfb="$color" ;;
      esac
    done

    printf "  %-12s ${cwb}%-14s${NC} ${csm}%-14s${NC} ${cfb}%-14s${NC}\n" \
      "$vm" "$col_wb" "$col_sm" "$col_fb"
  done

  echo ""
}

# ── Usage ────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: logging.sh [OPTIONS]

Control logging services (winlogbeat, sysmon, filebeat) across lab VMs.

Options:
  --enable  TARGET    Start logging services
  --disable TARGET    Stop logging services
  --status            Show status of all logging services
  -h, --help          Show this help message

Targets:
  all                 All running VMs
  <vm>                All services on a specific VM
  <vm>:<service>      A specific service on a specific VM

Examples:
  ./logging.sh --enable all              Start all logging on all running VMs
  ./logging.sh --disable all             Stop all logging on all running VMs
  ./logging.sh --enable dc1              Start all logging on dc1
  ./logging.sh --disable web1            Stop all logging on web1
  ./logging.sh --enable dc1:winlogbeat   Start winlogbeat on dc1
  ./logging.sh --disable ejbca1:filebeat Stop filebeat on ejbca1
  ./logging.sh --status                  Show status table of all logging services
EOF
  # VM lists are derived from topology.yml (vm-registry.sh), not hardcoded.
  printf '\nVMs:\n  Windows: %s\n  Linux:   %s\n' "${WINDOWS_VMS[*]}" "${LINUX_VMS[*]}"
  cat <<'EOF'

Services:
  winlogbeat  Windows Event Log forwarding (all Windows VMs)
  sysmon      System Monitor (all Windows VMs, service: Sysmon64)
  filebeat    Log file forwarding (Linux VMs + web1)
EOF
  exit 0
}

# ── Main ─────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  usage
fi

ACTION=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable)
      ACTION="enable"
      TARGET="${2:-}"
      if [[ -z "$TARGET" ]]; then
        echo "Error: --enable requires a target (e.g., all, dc1, dc1:winlogbeat)" >&2
        exit 1
      fi
      shift 2
      ;;
    --disable)
      ACTION="disable"
      TARGET="${2:-}"
      if [[ -z "$TARGET" ]]; then
        echo "Error: --disable requires a target (e.g., all, dc1, dc1:winlogbeat)" >&2
        exit 1
      fi
      shift 2
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 1
      ;;
  esac
done

case "$ACTION" in
  enable|disable)
    echo -e "${BOLD}${ACTION^} logging${NC}  (profile: $LAB_PROFILE_NAME)"
    echo ""
    do_enable_disable "$ACTION" "$TARGET"
    echo ""
    ;;
  status)
    do_status
    ;;
  *)
    usage
    ;;
esac
