#!/bin/bash
# Stub-vagrant tests for validate-harness.sh transport hardening: stderr
# capture, retry, and the guaranteed FAIL line replacing silent "vanish".
# Self-contained — shims `vagrant` and `ssh` on PATH; no VMs, no network.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/../scripts/lib/validate-harness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
export STUB_STATE="$WORK/state"
mkdir -p "$STUB_STATE"

cat > "$WORK/bin/vagrant" <<'STUB'
#!/bin/bash
cmd="$1"
case "$cmd" in
  upload) exit 0 ;;
  winrm|ssh)
    n_file="$STUB_STATE/calls"
    n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$n_file"
    if [[ "$n" -lt "${STUB_SUCCEED_AT:-99}" ]]; then
      echo "stub: WinRM connection refused (attempt $n)" >&2
      exit 1
    fi
    echo "PASS: stub check ok"
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/vagrant"
export PATH="$WORK/bin:$PATH"
export VALIDATE_RETRY_PAUSE=0

# shellcheck source=../scripts/lib/validate-harness.sh
source "$HARNESS"

fail() { echo "FAIL: $1"; exit 1; }
reset_calls() { rm -f "$STUB_STATE/calls"; }

# ── Test 1: both attempts fail → concrete FAIL line with stderr excerpt ──
reset_calls
export STUB_SUCCEED_AT=99
out="$WORK/t1.out"
run_windows_check vm1 'Write-Output "PASS: never runs"' "$out"
grep -q '^FAIL: check transport failed:' "$out" || fail "t1: no transport FAIL line"
grep -q 'connection refused' "$out" || fail "t1: stderr excerpt missing"
[[ "$(cat "$STUB_STATE/calls")" == "2" ]] || fail "t1: expected 2 attempts, got $(cat "$STUB_STATE/calls")"
[[ ! -f "$out.err" ]] || fail "t1: errfile not cleaned up"
echo "ok 1 - windows double-failure yields diagnosable FAIL"

# ── Test 2: first attempt fails, retry succeeds → PASS, no transport FAIL ──
reset_calls
export STUB_SUCCEED_AT=2
out="$WORK/t2.out"
run_windows_check vm1 'Write-Output "PASS: stub"' "$out"
grep -q '^PASS: stub check ok' "$out" || fail "t2: retry success not recorded"
grep -q 'transport failed' "$out" && fail "t2: spurious transport FAIL"
[[ "$(cat "$STUB_STATE/calls")" == "2" ]] || fail "t2: expected 2 attempts"
echo "ok 2 - windows retry recovers"

# ── Test 3: linux fallback path (no ip/key → vagrant ssh) double-failure ──
reset_calls
export STUB_SUCCEED_AT=99
lab_vm_ip() { echo ""; }
export VAGRANT_DOTFILE_PATH="$WORK/nonexistent"
out="$WORK/t3.out"
run_linux_check vm2 'echo "PASS: never runs"' "$out"
grep -q '^FAIL: check transport failed:' "$out" || fail "t3: no transport FAIL line"
[[ "$(cat "$STUB_STATE/calls")" == "2" ]] || fail "t3: expected 2 attempts"
echo "ok 3 - linux double-failure yields diagnosable FAIL"

# ── Test 4: linux retry recovers ──
reset_calls
export STUB_SUCCEED_AT=2
out="$WORK/t4.out"
run_linux_check vm2 'echo unused' "$out"
grep -q '^PASS: stub check ok' "$out" || fail "t4: retry success not recorded"
echo "ok 4 - linux retry recovers"

echo "validate_harness_test: 4/4 ok"
