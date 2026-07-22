#!/bin/bash
# scripts/lib/validate-harness.sh — validate.sh harness core.
#
# Pure function definitions sourced by validate.sh. They reference globals
# (RUNNING_VMS, FILTER_VMS, PASS_COUNT, FAIL_COUNT, SKIP_COUNT, FAILURES,
# CHECK_ORDER, PIDS, TMPDIR_VAL, RED/GREEN/YELLOW/NC, VAGRANT_DOTFILE_PATH,
# profile_has) that validate.sh defines/sources before invoking them.
[[ -n "${_VALIDATE_HARNESS_LOADED:-}" ]] && return 0
_VALIDATE_HARNESS_LOADED=1

record_result() {
    local vm="$1" line="$2"
    if [[ "$line" == PASS:* ]]; then
        printf "  ${GREEN}PASS${NC}  %-10s %s\n" "$vm" "${line#PASS: }"
        ((PASS_COUNT++)) || true
    elif [[ "$line" == FAIL:* ]]; then
        printf "  ${RED}FAIL${NC}  %-10s %s\n" "$vm" "${line#FAIL: }"
        ((FAIL_COUNT++)) || true
        FAILURES+=("$vm: ${line#FAIL: }")
    fi
}

skip_vm() {
    local vm="$1" reason="${2:-not running}"
    # Don't report skips for VMs the user didn't ask about
    if [[ ${#FILTER_VMS[@]} -gt 0 ]]; then
        local requested=false
        for f in "${FILTER_VMS[@]}"; do
            [[ "$f" == "$vm" ]] && requested=true
        done
        $requested || return 0
    fi
    # If the VM isn't in the active profile, swap the reason so the user
    # sees "not in profile" instead of "not running" (less alarming).
    if [[ "$reason" == "not running" ]] && ! profile_has "$vm"; then
        reason="not in profile '$LAB_PROFILE_NAME'"
    fi
    printf "  ${YELLOW}SKIP${NC}  %-10s %s\n" "$vm" "$reason"
    ((SKIP_COUNT++)) || true
}

is_running() {
    echo "$RUNNING_VMS" | grep -qx "$1" || return 1
    # If filter specified, only include listed VMs
    if [[ ${#FILTER_VMS[@]} -gt 0 ]]; then
        local vm
        for vm in "${FILTER_VMS[@]}"; do
            [[ "$vm" == "$1" ]] && return 0
        done
        return 1
    fi
    return 0
}

run_windows_check() {
    local vm="$1" ps1="$2" outfile="$3"
    # Use a unique remote filename per check so concurrent checks against the
    # same VM don't race on a shared C:\validate.ps1 (each launch_check runs
    # in the background). Derive from outfile basename which validate already
    # makes unique per check.
    local tag
    tag=$(basename "$outfile")
    local tmpfile="/tmp/validate-${vm}-${tag}.ps1"
    local remote="C:\\validate-${tag}.ps1"

    printf '%s' "$ps1" > "$tmpfile"
    if ! vagrant upload "$tmpfile" "$remote" "$vm" >/dev/null 2>&1; then
        echo "FAIL: Could not upload check script" > "$outfile"
        rm -f "$tmpfile"
        return
    fi

    # Run the uploaded script then delete it in the SAME winrm call so
    # no per-check C:\validate-*.ps1 debris accumulates on the VM. `& <file>`
    # honors the session's Bypass policy; Remove-Item is silent on success so it
    # adds nothing to $outfile (and a stray cleanup error is ignored — the
    # aggregator only reads PASS:/FAIL:/SKIP: lines).
    vagrant winrm -c "powershell.exe -ExecutionPolicy Bypass -Command \"& '$remote'; Remove-Item -Force -ErrorAction SilentlyContinue '$remote'\"" "$vm" 2>/dev/null > "$outfile" || true
    rm -f "$tmpfile"
}

# ─── Linux VM check: pipe script to vagrant ssh ──────────────────────────

# Linux VM host-only IPs. `vagrant ssh` would be cleaner but its NAT-forwarded
# ports collide silently when multiple VMs default to 2222 — `vagrant ssh
# ejbca1` ends up talking to dc1's sshd. Going direct via the host-only
# network is the unambiguous path; each VM's IP is resolved per-profile at call
# time via lab_vm_ip (lab-secrets.sh, sourced upstream) so it tracks the active
# profile's dynamically-allocated /24.

run_linux_check() {
    local vm="$1" script="$2" outfile="$3"
    local ip; ip="$(lab_vm_ip "$vm")"
    local key="$VAGRANT_DOTFILE_PATH/machines/$vm/virtualbox/private_key"
    if [[ -z "$ip" || ! -f "$key" ]]; then
        # Fallback to `vagrant ssh` (will work for VMs whose NAT port survives
        # the collision lottery; better than failing silently).
        printf '%s\n' "$script" | vagrant ssh "$vm" -- bash -s 2>/dev/null > "$outfile" || true
        return
    fi
    printf '%s\n' "$script" | ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
        -i "$key" "vagrant@$ip" bash -s 2>/dev/null > "$outfile" || true
}

# Returns 0 if the host has working internet (used to gate external-probe checks
# like cloudflare_pqc against public CF endpoints). Tests against 1.1.1.1 to
# avoid DNS dependencies. 5s timeout.
internet_reachable() {
    curl -sk --max-time 5 -o /dev/null https://1.1.1.1 2>/dev/null
}

# Emits a SKIP line for a single named check (vs skip_vm which targets a whole
# VM). Used when an individual check can't run for a known reason (e.g. host
# offline) but we still want it visible in the summary. Increments SKIP_COUNT.
skip_check() {
    local vm="$1" name="$2" reason="$3"
    printf "  ${YELLOW}SKIP${NC}  %-10s %s (%s)\n" "$vm" "$name" "$reason"
    ((SKIP_COUNT++)) || true
}

launch_check() {
    local vm="$1"
    shift
    CHECK_ORDER+=("$vm")
    "$@" &
    PIDS+=($!)
}
