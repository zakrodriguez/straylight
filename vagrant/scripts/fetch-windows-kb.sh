#!/usr/bin/env bash
# fetch-windows-kb.sh — Download a Windows hotfix .msu by KB number
#
# Microsoft Update Catalog (catalog.update.microsoft.com) is the only direct
# source for standalone .msu files, but it doesn't publish stable URLs — the
# direct download host (catalog.sf.dl.delivery.mp.microsoft.com) mints GUIDs
# per request. So this script:
#   1. Scrapes the catalog search page for the update's GUID.
#   2. POSTs to DownloadDialog.aspx to retrieve the current direct .msu URL.
#   3. Downloads to resources/software/<KB>.msu (the canonical cache path
#      that the windows_kb_install Ansible role looks for).
#   4. Computes SHA256 and prints it so the operator can pin it.
#   5. (Optional) Verifies against an expected SHA256 supplied via flag or
#      embedded in a known-pins file (resources/software/kb-pins.txt).
#
# Why a separate script (not part of cache-software.sh / software-manifest.yml):
#   The catalog's URL rotation makes manifest entries fragile.  This script
#   re-resolves the URL each run, so a stale pin in the manifest can't break
#   builds. The SHA256 is the integrity anchor, not the URL.
#
# Examples
# --------
#   # Fetch + print computed SHA256:
#   ./vagrant/scripts/fetch-windows-kb.sh KB5087539
#
#   # Fetch + verify against a pinned SHA256 (fail if mismatch):
#   ./vagrant/scripts/fetch-windows-kb.sh KB5087539 \
#       18bcf4eba2d04734b15685b6714fc16104ffc146f4dc77d94df1c03b043ce674
#
#   # Force re-download even if cache exists:
#   ./vagrant/scripts/fetch-windows-kb.sh --force KB5087539
#
# Known KBs + pins (extend kb-pins.txt as you cache new updates):
#   KB5087539  — Windows Server 2025 May 2026 cumulative
#                (adds ML-DSA-44/65/87 support to AD CS)
#                sha256 18bcf4eba2d04734b15685b6714fc16104ffc146f4dc77d94df1c03b043ce674

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/resources/software"
PINS_FILE="${CACHE_DIR}/kb-pins.txt"

mkdir -p "${CACHE_DIR}"

# ── ANSI ─────────────────────────────────────────────────────────────────
C_RESET=$'\033[0m'
C_STEEL=$'\033[38;5;39m'
C_GREEN=$'\033[38;5;28m'
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'
C_DIM=$'\033[2m'

info()  { echo "${C_STEEL}==> $*${C_RESET}"; }
ok()    { echo "  ${C_GREEN}OK${C_RESET}    $*"; }
warn()  { echo "  ${C_YELLOW}WARN${C_RESET}  $*"; }
fail()  { echo "  ${C_RED}FAIL${C_RESET}  $*" >&2; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────
FORCE=false
KB=""
EXPECTED_SHA=""

usage() {
  cat <<EOF
${C_STEEL}fetch-windows-kb.sh${C_RESET} — Resolve + download a Windows KB .msu from Microsoft Update Catalog

${C_STEEL}Usage:${C_RESET}
  fetch-windows-kb.sh [--force] <KB_NUMBER> [EXPECTED_SHA256]

${C_STEEL}Arguments:${C_RESET}
  KB_NUMBER         e.g. KB5087539  (matches ^KB[0-9]+\$)
  EXPECTED_SHA256   Optional lowercase hex; fails build if mismatch.
                    If omitted, the script will check kb-pins.txt for
                    a pinned value.

${C_STEEL}Options:${C_RESET}
  --force   Re-download even if {CACHE_DIR}/<KB>.msu already exists
  -h, --help

${C_STEEL}Cache:${C_RESET}
  Output:          ${CACHE_DIR}/<KB>.msu
  Pins (optional): ${PINS_FILE}
                   Format: <KB>  <sha256>  <description>

The Ansible windows_kb_install role expects the .msu at
{{ software_source }}\<KB>.msu, which resolves to C:\Software\<KB>.msu on
Windows VMs via the VirtualBox share at resources/software/.  This script
populates that same path on the host side.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force)   FORCE=true; shift ;;
    KB[0-9]*)
      if [[ -z "${KB}" ]]; then KB="$1"
      else fail "multiple KB numbers given"
      fi
      shift ;;
    [a-f0-9]*)
      if [[ ${#1} -eq 64 ]]; then EXPECTED_SHA="$1"; shift
      else fail "unrecognized argument: $1"
      fi ;;
    *) fail "unrecognized argument: $1" ;;
  esac
done

[[ -z "${KB}" ]] && { usage; exit 1; }
[[ "${KB}" =~ ^KB[0-9]+$ ]] || fail "KB must match ^KB[0-9]+$ (got: ${KB})"

# ── Pin lookup if not supplied ──────────────────────────────────────────
if [[ -z "${EXPECTED_SHA}" ]] && [[ -f "${PINS_FILE}" ]]; then
  EXPECTED_SHA=$(awk -v k="${KB}" '$1==k {print $2; exit}' "${PINS_FILE}" || true)
  if [[ -n "${EXPECTED_SHA}" ]]; then
    info "Found pinned SHA256 in $(basename "${PINS_FILE}")"
  fi
fi

OUTPUT="${CACHE_DIR}/${KB}.msu"

# ── Cache check ─────────────────────────────────────────────────────────
info "Target: ${OUTPUT}"
if [[ -f "${OUTPUT}" ]] && [[ "${FORCE}" != true ]]; then
  ACTUAL=$(sha256sum "${OUTPUT}" | awk '{print $1}')
  SIZE=$(numfmt --to=iec "$(stat -c %s "${OUTPUT}")")
  ok "${KB}.msu already present (${SIZE}, sha256 ${ACTUAL:0:16}...)"
  if [[ -n "${EXPECTED_SHA}" ]]; then
    if [[ "${ACTUAL}" == "${EXPECTED_SHA}" ]]; then
      ok "Pinned SHA256 verified"
      exit 0
    else
      warn "SHA256 mismatch — expected ${EXPECTED_SHA:0:16}..., got ${ACTUAL:0:16}..."
      info "Use --force to re-download"
      exit 1
    fi
  fi
  info "(No pin to verify against; pass EXPECTED_SHA256 or add to kb-pins.txt)"
  exit 0
fi

# ── Resolve update GUID from catalog search page ────────────────────────
info "Resolving ${KB} from Microsoft Update Catalog..."
SEARCH_URL="https://www.catalog.update.microsoft.com/Search.aspx?q=${KB}"
GUID=$(curl -sL "${SEARCH_URL}" \
    -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
    | grep -oE 'goToDetails\("[a-f0-9-]+"' \
    | head -1 \
    | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' \
    || true)

[[ -z "${GUID}" ]] && fail "Could not find update GUID for ${KB} (search returned no results — verify KB exists in the catalog)"
ok "Update GUID: ${GUID}"

# ── POST to DownloadDialog to get direct .msu URL ───────────────────────
info "Requesting direct download URL..."
POST_BODY="[{\"size\":0,\"languages\":\"\",\"uidInfo\":\"${GUID}\",\"updateID\":\"${GUID}\"}]"
ESCAPED_BODY=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" <<< "${POST_BODY}")

MSU_URL=$(curl -sL "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" \
    -A "Mozilla/5.0" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "updateIDs=${ESCAPED_BODY}" \
    | grep -oE "https://[^'\"]+${KB,,}[^'\"]+\.msu" \
    | head -1 \
    || true)

[[ -z "${MSU_URL}" ]] && fail "Catalog returned no direct .msu URL — the update may have multiple variants requiring manual selection"
ok "Direct URL: $(basename "${MSU_URL}")"

# ── Download ────────────────────────────────────────────────────────────
info "Downloading to ${OUTPUT}..."
START=$(date +%s)
if ! curl -fSL --progress-bar -o "${OUTPUT}" "${MSU_URL}"; then
  rm -f "${OUTPUT}"
  fail "Download failed"
fi
ELAPSED=$(($(date +%s) - START))
SIZE=$(numfmt --to=iec "$(stat -c %s "${OUTPUT}")")
ok "Downloaded ${SIZE} in $((ELAPSED / 60))m $((ELAPSED % 60))s"

# ── Hash + verify ───────────────────────────────────────────────────────
info "Computing SHA256..."
ACTUAL=$(sha256sum "${OUTPUT}" | awk '{print $1}')
ok "SHA256: ${ACTUAL}"

if [[ -n "${EXPECTED_SHA}" ]]; then
  if [[ "${ACTUAL}" == "${EXPECTED_SHA}" ]]; then
    ok "Pinned SHA256 verified"
  else
    warn "SHA256 mismatch — expected ${EXPECTED_SHA}, got ${ACTUAL}"
    fail "Integrity check failed.  Delete ${OUTPUT} and retry, or update the pin."
  fi
else
  info "No pin supplied.  To pin: append the following to ${PINS_FILE}:"
  echo ""
  echo "  ${KB}  ${ACTUAL}  <description>"
  echo ""
fi

info "Ready for windows_kb_install role:"
echo "  ansible-playbook -i <inventory> vagrant/ansible/playbooks/install-windows-kb.yml \\"
echo "    -e kb_number=${KB} -e target=<host>"
