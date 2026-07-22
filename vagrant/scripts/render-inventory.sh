#!/bin/bash
# render-inventory.sh — regenerate ansible/inventory/<profile>/{static,pqc}.ini
# for the active LAB_PROFILE. Just delegates to the Vagrantfile, which writes
# both inventory files at parse time as a side effect.
#
# Per-profile subdirectories isolate concurrent profiles from each other —
# running two LAB_PROFILE values in parallel terminals no longer races on
# inventory writes (each profile writes to its own dir; writes are atomic).
#
# Use this when you've changed LAB_PROFILE / LAB_COMPONENTS but haven't yet
# run `vagrant up` / `vagrant status`. Most of the time you don't need it —
# any vagrant operation regenerates inventories automatically.
#
# Usage:
#   LAB_PROFILE=pqc-linux bash scripts/render-inventory.sh
#   LAB_COMPONENTS=observe1,scanner1 bash scripts/render-inventory.sh
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR/.."

# Resolve active profile name (sets LAB_PROFILE_NAME).
source "$_SCRIPT_DIR/lib/profile-helper.sh"

# vagrant status with no args parses the Vagrantfile and exits cheaply.
# LAB_RENDER_INVENTORY=1 tells the Vagrantfile to (re)generate the inventories
# during this parse — a bare `vagrant status` no longer does so.
# >/dev/null hides the VM listing.
LAB_RENDER_INVENTORY=1 vagrant status >/dev/null 2>&1 || true

# Confirm by printing the active profile + inventory paths.
INV_STATIC="ansible/inventory/$LAB_PROFILE_NAME/static.ini"
INV_PQC="ansible/inventory/$LAB_PROFILE_NAME/pqc.ini"
echo "rendered:"
echo "  $INV_STATIC ($(wc -l < $INV_STATIC) lines)"
echo "  $INV_PQC ($(wc -l < $INV_PQC) lines)"
