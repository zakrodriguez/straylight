#!/bin/bash
# Clean up after a Ctrl+C'd up.sh run.
# Kills stale vagrant/ansible processes, clears lock files, shows VM status.

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_CYAN=$'\033[38;5;39m'
C_GREEN=$'\033[38;5;28m'
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR"

# Resolve active profile (sets LAB_PROFILE_NAME, VAGRANT_DOTFILE_PATH).
source "$_SCRIPT_DIR/scripts/lib/profile-helper.sh"

echo "${C_CYAN}clean.sh${C_RESET} ${C_DIM}— profile: ${LAB_PROFILE_NAME} (dotfile: ${VAGRANT_DOTFILE_PATH})${C_RESET}"
echo ""

DIRTY=false

# ── Kill stale processes ──────────────────────────────────────────────
PATTERNS=("vagrant" "ansible-playbook" "ruby.*vagrant")

for pat in "${PATTERNS[@]}"; do
  # Find matching processes (exclude this script and the pkill/pgrep itself)
  if pids=$(pgrep -f "$pat" 2>/dev/null); then
    while IFS= read -r pid; do
      # Skip our own process and parent shell
      [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
      cmdline=$(ps -p "$pid" -o args= 2>/dev/null) || continue
      # Skip this script itself
      [[ "$cmdline" == *"clean.sh"* ]] && continue
      echo "${C_RED}Killing${C_RESET} PID ${pid}: ${C_DIM}${cmdline}${C_RESET}"
      kill "$pid" 2>/dev/null || true
      DIRTY=true
    done <<< "$pids"
  fi
done

# ── Clear lock files ──────────────────────────────────────────────────
LOCK_PATTERNS=(
  "$HOME/.vagrant.d/data/lock.*.lock"
  "$HOME/.vagrant.d/data/machine-index/index.lock"
)

for glob in "${LOCK_PATTERNS[@]}"; do
  # $glob is intentionally unquoted here so the shell expands the wildcard
  # (the patterns contain *). The loop variable below stays quoted for
  # consistency with the rest of the codebase; the [[ -f ]] guard skips the
  # literal pattern when a glob matches nothing.
  # shellcheck disable=SC2086
  for lockfile in $glob; do
    [[ -f "$lockfile" ]] || continue
    echo "${C_YELLOW}Removing${C_RESET} lock: ${C_DIM}${lockfile}${C_RESET}"
    rm -f "$lockfile"
    DIRTY=true
  done
done

# ── Summary ───────────────────────────────────────────────────────────
echo ""
if [[ "$DIRTY" == false ]]; then
  echo "${C_GREEN}All clean${C_RESET} ${C_DIM}— nothing to clean up${C_RESET}"
else
  echo "${C_GREEN}Cleanup complete${C_RESET}"
fi

# ── VM status ─────────────────────────────────────────────────────────
echo ""
echo "${C_DIM}VM status:${C_RESET}"
vagrant status 2>/dev/null || echo "${C_DIM}(vagrant status unavailable)${C_RESET}"
