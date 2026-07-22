#!/usr/bin/env bash
# run-all-commands.sh — Smoke-check every command shown in every lesson.
#
# For each lesson markdown, extract all fenced bash blocks (lines starting
# with $ or openssl), run them, and report any failures.
#
# Prereq: bootstrap.sh has run and certs/ is populated.
#
# Usage: bash tools/run-all-commands.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -d "$LAB_DIR/certs" || -z "$(ls -A "$LAB_DIR/certs" 2>/dev/null)" ]]; then
  echo "ERROR: $LAB_DIR/certs is empty. Run bootstrap.sh first." >&2
  exit 2
fi

failures=0
total=0
for lesson in "$LAB_DIR"/lessons/[0-9]*-*.md; do
  [[ -f "$lesson" ]] || continue
  echo "── $(basename "$lesson") ──"

  # Extract all bash blocks (lines between ```bash and ```), strip the
  # leading "$ " prompt that lessons use as a visual cue, skip lines that
  # are purely visual ("Expected output:" etc).
  block=""
  in_block=false
  while IFS= read -r line; do
    if [[ "$line" == '```bash' || "$line" == '```sh' ]]; then
      in_block=true; block=""; continue
    fi
    if $in_block && [[ "$line" == '```' ]]; then
      in_block=false
      # Run the block, captured stdout muted (we only care about exit).
      while IFS= read -r cmd; do
        # Strip leading "$ " or "# "
        cmd="${cmd#\$ }"
        cmd="${cmd#\# }"
        [[ -z "${cmd// }" ]] && continue
        total=$((total + 1))
        if ! ( cd "$LAB_DIR" && eval "$cmd" ) >/dev/null 2>&1; then
          echo "  ✗ FAIL: $cmd"
          failures=$((failures + 1))
        fi
      done <<<"$block"
      block=""; continue
    fi
    if $in_block; then
      block+="${line}"$'\n'
    fi
  done < "$lesson"
done

echo
echo "Total commands: $total, Failures: $failures"
exit "$failures"
