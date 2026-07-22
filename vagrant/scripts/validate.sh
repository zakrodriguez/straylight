#!/bin/bash
# validate.sh — Post-build health check for straylight PKI lab
# Runs all VM checks in parallel for fast results.
#
# Usage:
#   bash scripts/validate.sh              # validate all running VMs
#   bash scripts/validate.sh dc1 ca1      # validate only dc1 and ca1
#   LAB_PROFILE=pqc-linux bash scripts/validate.sh
#
# Structure (decomposed from the former 2,459-line monolith):
#   lib/validate-harness.sh   harness core (record_result, launch_check, the
#                             run_*_check transports, is_running, skip_*)
#   checks/common.sh          shared ps_check_* PowerShell snippets
#   checks/<vm>.sh            per-VM assertions as register_checks_<vm>()
#   This file: bootstrap, profile/VM discovery, dispatch, aggregation.

set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILURES=()

# Temp dir for parallel output. Register the cleanup trap at mktemp time so a
# failure later in the script can't leak the dir; the previous order set the
# trap after mktemp, so a mktemp failure would have left no trap installed.
TMPDIR_VAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_VAL"' EXIT

START_TIME=$(date +%s)

# ─── Active LAB_PROFILE (matches up.sh / clean.sh / nuke.sh / snap.sh) ───
# Sets LAB_PROFILE_NAME, LAB_PROFILE_COMPONENTS_ARR, VAGRANT_DOTFILE_PATH,
# profile_has(). is_running() additionally consults the profile so checks
# targeting VMs outside the active profile get a clear "not in profile"
# skip message instead of being silently absent.
source "$_SCRIPT_DIR/lib/profile-helper.sh"
source "$_SCRIPT_DIR/lib/lab-secrets.sh"      # lab_groupvar() — no hardcoded creds
source "$_SCRIPT_DIR/lib/validate-harness.sh" # harness core
TOPOLOGY="$LAB_PROFILE_NAME"  # legacy var; cosmetic banner only + ejbca1 check

# ─── per-run log artifact (mirrors up.sh's logs/<ts>/ convention) ──
# validate runs previously left nothing on disk to triage. Tee the whole run
# to a timestamped log; the file copy has ANSI stripped so it greps cleanly.
VALIDATE_LOG_DIR="${VALIDATE_LOG_DIR:-logs/$(date '+%Y%m%d-%H%M%S')}"
mkdir -p "$VALIDATE_LOG_DIR"
VALIDATE_LOG="$VALIDATE_LOG_DIR/validate.log"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$VALIDATE_LOG")) 2>&1
printf 'validate.sh — profile %s — %s\n\n' \
    "$LAB_PROFILE_NAME" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$VALIDATE_LOG"

# ─── Detect running VMs ─────────────────────────────────────────────────

if ! command -v vagrant &>/dev/null; then
    echo "Error: vagrant not found in PATH" >&2
    exit 1
fi

RUNNING_VMS=$(vagrant status --machine-readable 2>/dev/null | \
    awk -F',' '$3 == "state" && $4 == "running" { print $2 }')

if [[ -z "$RUNNING_VMS" ]]; then
    echo "No running VMs found. Nothing to validate."
    exit 0
fi

# ─── VM filter (positional args) ────────────────────────────────────────
FILTER_VMS=("$@")

# Validate filter args against running VMs
for vm in "${FILTER_VMS[@]}"; do
    if ! echo "$RUNNING_VMS" | grep -qx "$vm"; then
        printf "${YELLOW}WARN${NC}  %s is not running — skipping\n" "$vm"
    fi
done

# ─── Lab identity defaults (overridable via env vars) ──────────────────
LAB_NETWORK="${LAB_NETWORK:-$(lab_network)}"       # active profile's /24 from rendered inventory
LAB_NETWORK="${LAB_NETWORK:-192.168.56}"           # fallback if inventory not yet rendered
LAB_DOMAIN="${LAB_DOMAIN:-yourlab.local}"
DC1_IP="${DC1_IP:-$(lab_vm_ip dc1)}"               # subnet-correct dc1 IP from inventory
DC1_IP="${DC1_IP:-${LAB_NETWORK}.10}"              # fallback when dc1 absent/unrendered

printf "${BOLD}=== straylight Validation — profile: %s (%d components) ===${NC}\n\n" \
    "$LAB_PROFILE_NAME" "${#LAB_PROFILE_COMPONENTS_ARR[@]}"
if [[ ${#FILTER_VMS[@]} -gt 0 ]]; then
    printf "Validating: %s\n\n" "${FILTER_VMS[*]}"
else
    printf "Running VMs: %s\n\n" "$(echo $RUNNING_VMS | tr '\n' ' ')"
fi

# ─── Load check definitions (checks/common.sh + checks/<vm>.sh) ─────────
for _cf in "$_SCRIPT_DIR"/checks/*.sh; do
    source "$_cf"
done

# ═════════════════════════════════════════════════════════════════════════
# Launch all VM checks in parallel
# ═════════════════════════════════════════════════════════════════════════

CHECK_ORDER=()
PIDS=()

# Dispatch order is significant: it fixes the result-print order below and must
# match the pre-decomposition sequence so output stays byte-stable. Each
# register_checks_* call reproduces its original `if is_running …` block.
register_checks_dc1
register_checks_dc2
register_checks_web1
register_checks_rootca
register_checks_issueca
register_checks_rootca_pqc
register_checks_issueca_pqc
register_checks_ca1
register_checks_client1
register_checks_manage1
register_checks_wsus1
register_checks_tomcat1
register_checks_ejbca1
register_checks_stepca1
register_checks_acme1
register_checks_observe1
register_checks_hydra1
register_checks_pqc_chimera

# ═════════════════════════════════════════════════════════════════════════
# Wait for all checks, then print results in order
# ═════════════════════════════════════════════════════════════════════════

for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

for vm in "${CHECK_ORDER[@]}"; do
    outfile="$TMPDIR_VAL/$vm"
    # A check that errored under `set -e` / `|| true` used to emit no
    # PASS/FAIL line and vanish silently. Track whether each launched check
    # produced ANY recognized result (PASS/FAIL/SKIP); if not, surface it as a
    # FAIL instead of dropping it. SKIP-only output (e.g. ejbca1-pqc when
    # pqc-migrate never ran) counts as "ran" — only genuine no-output vanishes.
    produced=0
    if [[ -f "$outfile" ]]; then
        while IFS= read -r line; do
            line="${line%%$'\r'}"
            case "$line" in
                PASS:*|FAIL:*) record_result "$vm" "$line"; produced=1 ;;
                SKIP:*)        produced=1 ;;
            esac
        done < "$outfile"
    fi
    if [[ "$produced" -eq 0 ]]; then
        record_result "$vm" "FAIL: check produced no result (vanished — script errored or output was lost)"
    fi
    echo ""
done

# ═════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════

ELAPSED=$(( $(date +%s) - START_TIME ))
printf "${BOLD}=== Summary (%ds) ===${NC}\n" "$ELAPSED"
printf "  ${GREEN}PASS${NC}: %d    ${RED}FAIL${NC}: %d    ${YELLOW}SKIP${NC}: %d\n" \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
printf "  log: %s\n" "$VALIDATE_LOG"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    printf "${RED}Failures:${NC}\n"
    for f in "${FAILURES[@]}"; do
        printf "  - %s\n" "$f"
    done
    exit 1
fi

exit 0
