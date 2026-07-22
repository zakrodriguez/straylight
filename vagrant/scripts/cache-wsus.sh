#!/usr/bin/env bash
# Capture the WsusContent binaries from a synced WSUS1 into the golden master cache
# (resources/software/wsus-cache/WsusContent). Run AFTER the content download has
# finished (it downloads asynchronously after the wsus1 provision completes).
#
# Usage:  LAB_PROFILE=<profile-with-wsus1> scripts/cache-wsus.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # vagrant/

: "${LAB_PROFILE:?Set LAB_PROFILE to the profile whose wsus1 you want to capture}"
export VAGRANT_DOTFILE_PATH="${VAGRANT_DOTFILE_PATH:-.vagrant-${LAB_PROFILE}}"

echo "[cache-wsus] capturing WsusContent from wsus1 (profile: ${LAB_PROFILE})…"
vagrant provision wsus1 --provision-with wsus-capture
echo "[cache-wsus] done — see resources/software/wsus-cache/WsusContent"
