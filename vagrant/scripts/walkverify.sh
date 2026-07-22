#!/bin/bash
# Thin launcher for the walkverify harness (cwd-independent).
# Usage: walkverify.sh {lint|verify|check} <lab.md> [--companion P] [--profile P]
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/walkverify" "$@"
