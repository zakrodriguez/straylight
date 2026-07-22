#!/bin/bash
# migrate-dotfile.sh — one-time migration of legacy Vagrant dotfile dirs
# to the per-profile naming scheme introduced by the composable-lab
# refactor.
#
# Old scheme:
#   .vagrant/      (default; was used by ADCS_TOPOLOGY=two-tier)
#   .vagrant-1t/   (was used by ADCS_TOPOLOGY=one-tier)
#
# New scheme:
#   .vagrant-<profile>/   one dotfile dir per active LAB_PROFILE.
#
# This script:
#   - Detects legacy dirs in vagrant/.
#   - Maps each onto the equivalent new profile dir.
#   - Dry-runs by default. Pass --confirm to actually rename.
#
# Renaming preserves Vagrant's machine state (UUIDs, snapshot pointers,
# private SSH keys) so the new dotfile dir picks up exactly where the
# old one left off — no rebuild needed.
#
# Usage:
#   bash scripts/migrate-dotfile.sh           # dry-run
#   bash scripts/migrate-dotfile.sh --confirm # actually rename

set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR/.."

source "$(dirname "${BASH_SOURCE[0]}")/lib/colors.sh"

CONFIRM=false
case "${1:-}" in
  --confirm) CONFIRM=true ;;
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  "") ;;
  *) echo "Unknown option: $1"; exit 1 ;;
esac

# Mapping: legacy dotfile name → new profile dotfile name.
# .vagrant/ was the two-tier default (ADCS_TOPOLOGY unset or =two-tier).
# .vagrant-1t/ was the one-tier opt-in.
declare -A MIGRATIONS=(
  [".vagrant"]=".vagrant-ad-cs-two-tier"
  [".vagrant-1t"]=".vagrant-ad-cs-one-tier"
)

echo "${C_CYAN}migrate-dotfile.sh${C_RESET} ${C_DIM}— legacy → per-profile dotfile rename${C_RESET}"
echo ""

ANY_FOUND=false
PLANNED=()

for legacy in "${!MIGRATIONS[@]}"; do
  new="${MIGRATIONS[$legacy]}"
  if [[ ! -d "$legacy" ]]; then
    continue
  fi
  ANY_FOUND=true

  if [[ -d "$new" ]]; then
    printf "  ${C_RED}CONFLICT${C_RESET}  %s ${C_DIM}→${C_RESET} %s ${C_RED}(target already exists, skipping)${C_RESET}\n" "$legacy" "$new"
    continue
  fi

  # Sanity: check that this looks like a real Vagrant dotfile dir.
  if [[ ! -d "$legacy/machines" ]]; then
    printf "  ${C_YELLOW}SKIP${C_RESET}  %s ${C_DIM}(no machines/ subdir — not a Vagrant dotfile)${C_RESET}\n" "$legacy"
    continue
  fi

  # Inventory the machines inside.
  machines=()
  while IFS= read -r m; do
    machines+=("$(basename "$m")")
  done < <(find "$legacy/machines" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  printf "  ${C_GREEN}MIGRATE${C_RESET}   %s ${C_DIM}→${C_RESET} %s\n" "$legacy" "$new"
  if [[ ${#machines[@]} -gt 0 ]]; then
    printf "    ${C_DIM}machines:${C_RESET} %s\n" "${machines[*]}"
  fi
  PLANNED+=("$legacy:$new")
done

echo ""

if ! $ANY_FOUND; then
  echo "${C_GREEN}Nothing to migrate${C_RESET} — no legacy dotfile dirs found."
  echo "${C_DIM}Looked for: ${!MIGRATIONS[*]}${C_RESET}"
  exit 0
fi

if [[ ${#PLANNED[@]} -eq 0 ]]; then
  echo "${C_YELLOW}No actionable migrations.${C_RESET} Resolve the conflicts above first."
  exit 1
fi

if ! $CONFIRM; then
  echo "${C_YELLOW}DRY RUN${C_RESET} — re-run with ${C_CYAN}--confirm${C_RESET} to perform the rename(s)."
  echo ""
  echo "  After migrating, build/operate with the corresponding profile, e.g.:"
  for pair in "${PLANNED[@]}"; do
    new="${pair#*:}"
    profile="${new#.vagrant-}"
    echo "    LAB_PROFILE=$profile bash up.sh"
  done
  exit 0
fi

# Perform renames.
echo "${C_CYAN}Renaming…${C_RESET}"
failures=0
for pair in "${PLANNED[@]}"; do
  legacy="${pair%%:*}"
  new="${pair#*:}"
  if mv "$legacy" "$new"; then
    printf "  ${C_GREEN}done${C_RESET}  %s ${C_DIM}→${C_RESET} %s\n" "$legacy" "$new"
  else
    printf "  ${C_RED}FAIL${C_RESET}  %s\n" "$legacy"
    (( failures++ )) || true
  fi
done

echo ""
if [[ $failures -gt 0 ]]; then
  echo "${C_RED}$failures migration(s) failed.${C_RESET}"
  exit 1
fi

echo "${C_GREEN}Migration complete.${C_RESET}"
echo ""
echo "Verify with:"
for pair in "${PLANNED[@]}"; do
  new="${pair#*:}"
  profile="${new#.vagrant-}"
  echo "  LAB_PROFILE=$profile vagrant status"
done
