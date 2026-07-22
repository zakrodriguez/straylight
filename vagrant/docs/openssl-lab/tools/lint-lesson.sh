#!/usr/bin/env bash
# lint-lesson.sh — Verify a lesson markdown has all 5 required H2 sections.
# Usage: bash tools/lint-lesson.sh lessons/NN-topic.md [more.md ...]
set -euo pipefail

REQUIRED=(
  "## Goal"
  "## Setup"
  "## Walkthrough"
  "## Self-check"
  "## Cross-references"
)

if [[ $# -eq 0 ]]; then
  echo "Usage: bash tools/lint-lesson.sh <lesson.md> [more.md ...]" >&2
  exit 2
fi

failures=0
for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "✗ $f: not found"
    failures=$((failures + 1))
    continue
  fi
  missing=()
  for h in "${REQUIRED[@]}"; do
    if ! grep -qFx "$h" "$f"; then
      missing+=("$h")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "✓ $f"
  else
    echo "✗ $f missing sections: ${missing[*]}"
    failures=$((failures + 1))
  fi
done

exit "$failures"
