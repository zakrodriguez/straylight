#!/bin/bash
# cbom-scan.sh — Export cryptographic assets from straylight lab VMs and generate a CBOM.
#
# Phase 1: Export certs, keys, CRLs from all running VMs into a staging directory.
# Phase 2: Run cbomkit-theia against the staging directory to produce CycloneDX CBOM JSON.
#
# Usage:
#   bash scripts/cbom-scan.sh                    # scan all running VMs
#   bash scripts/cbom-scan.sh dc1 ca1 web1       # scan specific VMs
#   bash scripts/cbom-scan.sh --export-only       # export certs only, skip cbomkit-theia
#
# Prerequisites:
#   - cbomkit-theia on PATH, OR Docker available (falls back to container image)
#   - VMs running and reachable via vagrant winrm / vagrant ssh

set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR/.."

# Resolve active profile (sets LAB_PROFILE_NAME, VAGRANT_DOTFILE_PATH).
source "$_SCRIPT_DIR/lib/profile-helper.sh"

# VM taxonomy from topology.yml (single source of truth).
source "$_SCRIPT_DIR/lib/vm-registry.sh"

# ── Options ──────────────────────────────────────────────────────────────
EXPORT_ONLY=false
SCAN_ONLY=false
FILTER_VMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-only) EXPORT_ONLY=true; shift ;;
    --scan-only)   SCAN_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--export-only] [--scan-only] [vm1 vm2 ...]"
      echo ""
      echo "  --export-only    Export certs from VMs but don't run cbomkit-theia"
      echo "  --scan-only      Run cbomkit-theia on existing cbom-export/ (no VMs needed)"
      echo "  vm1 vm2 ...      Only scan these VMs (default: all running)"
      exit 0 ;;
    *) FILTER_VMS+=("$1"); shift ;;
  esac
done

# ── Colors ───────────────────────────────────────────────────────────────
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_CYAN=$'\033[38;5;39m'
C_GREEN=$'\033[38;5;28m'
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'
C_BOLD=$'\033[1m'

# ── Detect running VMs ──────────────────────────────────────────────────
RUNNING_VMS=$(vagrant status --machine-readable 2>/dev/null | \
  awk -F',' '$3 == "state" && $4 == "running" { print $2 }')

is_running() { echo "$RUNNING_VMS" | grep -qx "$1"; }

should_scan() {
  is_running "$1" || return 1
  if [[ ${#FILTER_VMS[@]} -gt 0 ]]; then
    for f in "${FILTER_VMS[@]}"; do
      [[ "$f" == "$1" ]] && return 0
    done
    return 1
  fi
  return 0
}

# ── Staging directory ───────────────────────────────────────────────────
SCAN_DIR="cbom-export"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
# Match cbom-pipeline.sh's filename convention (lab_profile_name, not the
# deprecated $TOPOLOGY variable). Before this fix the unset var rendered
# filenames as "cbom---<timestamp>.json".
CBOM_OUTPUT="cbom-${LAB_PROFILE_NAME}-${TIMESTAMP}.json"

if $SCAN_ONLY; then
  if [[ ! -d "$SCAN_DIR" ]] || [[ -z "$(find "$SCAN_DIR" -type f 2>/dev/null)" ]]; then
    printf "${C_RED}No files in %s/ — run without --scan-only first to export.${C_RESET}\n" "$SCAN_DIR"
    exit 1
  fi
  TOTAL_FILES=$(find "$SCAN_DIR" -type f | wc -l)
  printf "${C_BOLD}=== CBOM Scan (%s) ===${C_RESET}\n\n" "$LAB_PROFILE_NAME"
  printf "  ${C_DIM}Skipping export — using existing %d files in %s/${C_RESET}\n\n" "$TOTAL_FILES" "$SCAN_DIR"
else

rm -rf "$SCAN_DIR"
mkdir -p "$SCAN_DIR"

printf "${C_BOLD}=== CBOM Scan (%s) ===${C_RESET}\n\n" "$LAB_PROFILE_NAME"

# ── Windows VM: export certs via WinRM ──────────────────────────────────

export_windows_certs() {
  local vm="$1"
  local outdir="$SCAN_DIR/$vm"
  mkdir -p "$outdir"

  local ps_script='
$outDir = "C:\cbom-export"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -Path $outDir -ItemType Directory -Force | Out-Null

$stores = @("My", "Root", "CA", "Trust")
foreach ($store in $stores) {
    $certs = Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue
    foreach ($cert in $certs) {
        try {
            $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $filename = "${store}_$($cert.Thumbprint).cer"
            [IO.File]::WriteAllBytes("$outDir\$filename", $bytes)
        } catch { }
    }
}

# Export CRL files if present (WEB1, CA1)
$crlPaths = @("C:\PKI\CRL", "C:\Windows\System32\CertSrv\CertEnroll")
foreach ($p in $crlPaths) {
    if (Test-Path $p) {
        Get-ChildItem "$p\*.crl" -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName "$outDir\$($_.Name)" }
    }
}

# Export AIA certs if present (WEB1)
$aiaPaths = @("C:\PKI\AIA")
foreach ($p in $aiaPaths) {
    if (Test-Path $p) {
        Get-ChildItem "$p\*.crt" -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName "$outDir\$($_.Name)" }
    }
}

# Count what we found
$count = (Get-ChildItem $outDir -File).Count
Write-Output "EXPORTED:$count"
'

  # Upload and run the export script
  local tmpfile="/tmp/cbom-export-${vm}.ps1"
  printf '%s' "$ps_script" > "$tmpfile"

  if ! vagrant upload "$tmpfile" "C:\\cbom-export.ps1" "$vm" >/dev/null 2>&1; then
    printf "  ${C_RED}FAIL${C_RESET}  ${C_CYAN}%-12s${C_RESET} upload failed\n" "$vm"
    rm -f "$tmpfile"
    return 1
  fi

  local result
  result=$(vagrant winrm -c "powershell.exe -ExecutionPolicy Bypass -File C:\cbom-export.ps1" "$vm" 2>/dev/null) || true
  rm -f "$tmpfile"

  local count
  count=$(echo "$result" | grep -oP 'EXPORTED:\K\d+' || echo "0")

  # Download exported files
  # vagrant doesn't have a native download, so we use a workaround:
  # read each file via WinRM and save locally
  local dl_script='
Get-ChildItem C:\cbom-export -File | ForEach-Object {
    $name = $_.Name
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
    Write-Output "FILE:${name}:${b64}"
}
'
  local dl_tmp="/tmp/cbom-dl-${vm}.ps1"
  printf '%s' "$dl_script" > "$dl_tmp"
  vagrant upload "$dl_tmp" "C:\\cbom-dl.ps1" "$vm" >/dev/null 2>&1 || true

  local dl_result
  dl_result=$(vagrant winrm -c "powershell.exe -ExecutionPolicy Bypass -File C:\cbom-dl.ps1" "$vm" 2>/dev/null) || true
  rm -f "$dl_tmp"

  local dl_count=0
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    if [[ "$line" == FILE:* ]]; then
      local fname b64
      fname=$(echo "$line" | cut -d: -f2)
      b64=$(echo "$line" | cut -d: -f3-)
      echo "$b64" | base64 -d > "$outdir/$fname" 2>/dev/null && dl_count=$((dl_count + 1))
    fi
  done <<< "$dl_result"

  # Cleanup remote
  vagrant winrm -c "powershell.exe -Command \"Remove-Item C:\\cbom-export, C:\\cbom-export.ps1, C:\\cbom-dl.ps1 -Recurse -Force -ErrorAction SilentlyContinue\"" "$vm" >/dev/null 2>&1 || true

  printf "  ${C_GREEN}OK${C_RESET}    ${C_CYAN}%-12s${C_RESET} %d files\n" "$vm" "$dl_count"
}

# ── Linux VM: export certs from Docker containers + host ────────────────

export_linux_certs() {
  local vm="$1"
  local outdir="$SCAN_DIR/$vm"
  mkdir -p "$outdir"

  local script='
set -e
OUTDIR="/tmp/cbom-export"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Host certificates. /opt/pqc-certs holds lab-enrolled ML-DSA leaves
# from ejbca_pqc_enroll role. Filter out *-key.pem / *.key so private
# key material does not transit the controller.
for dir in /etc/ssl/certs /etc/pki/tls/certs /usr/local/share/ca-certificates /opt/pqc-certs; do
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 2 -type f \( -name "*.pem" -o -name "*.crt" -o -name "*.cer" \) \
      -not -name "*-key.pem" -not -name "*.key" 2>/dev/null | while read f; do
      cp "$f" "$OUTDIR/host_$(basename "$f")" 2>/dev/null || true
    done
  fi
done

# Docker container certificates and keys
for ctr in $(docker ps --format "{{.Names}}" 2>/dev/null); do
  for path in /etc/ssl /etc/pki /opt/step/certs /home/step/certs /var/lib/ejbca /opt/keyfactor; do
    docker exec "$ctr" find "$path" -maxdepth 3 -type f \( -name "*.pem" -o -name "*.crt" -o -name "*.cer" -o -name "*.key" -o -name "*.p12" \) 2>/dev/null | while read f; do
      safe_name=$(echo "${ctr}_$(basename "$f")" | tr "/" "_")
      docker cp "${ctr}:${f}" "$OUTDIR/$safe_name" 2>/dev/null || true
    done
  done
done

count=$(find "$OUTDIR" -type f | wc -l)
echo "EXPORTED:${count}"

# Base64-encode each file for transfer
find "$OUTDIR" -type f | while read f; do
  name=$(basename "$f")
  b64=$(base64 -w0 "$f")
  echo "FILE:${name}:${b64}"
done
'

  local result
  result=$(printf '%s\n' "$script" | vagrant ssh "$vm" -- bash -s 2>/dev/null) || true

  local dl_count=0
  while IFS= read -r line; do
    if [[ "$line" == FILE:* ]]; then
      local fname b64
      fname=$(echo "$line" | cut -d: -f2)
      b64=$(echo "$line" | cut -d: -f3-)
      echo "$b64" | base64 -d > "$outdir/$fname" 2>/dev/null && dl_count=$((dl_count + 1))
    fi
  done <<< "$result"

  # Cleanup remote
  printf '%s\n' 'rm -rf /tmp/cbom-export' | vagrant ssh "$vm" -- bash -s 2>/dev/null || true

  printf "  ${C_GREEN}OK${C_RESET}    ${C_CYAN}%-12s${C_RESET} %d files\n" "$vm" "$dl_count"
}

# ── Phase 1: Export from all VMs in parallel ────────────────────────────

# Derived from topology.yml via vm-registry.sh (was a hardcoded list that
# omitted scanner1/acme1/apps1 + the PQC CAs/sqlhost1).
mapfile -t WINDOWS_VMS < <(vm_windows)
mapfile -t LINUX_VMS < <(vm_linux)

printf "${C_CYAN}── Phase 1: Exporting cryptographic assets ──${C_RESET}\n\n"

declare -A EXPORT_PIDS

for vm in "${WINDOWS_VMS[@]}"; do
  should_scan "$vm" || continue
  export_windows_certs "$vm" &
  EXPORT_PIDS[$vm]=$!
done

for vm in "${LINUX_VMS[@]}"; do
  should_scan "$vm" || continue
  export_linux_certs "$vm" &
  EXPORT_PIDS[$vm]=$!
done

# Wait for all exports
EXPORT_FAILURES=0
for vm in "${!EXPORT_PIDS[@]}"; do
  if ! wait "${EXPORT_PIDS[$vm]}" 2>/dev/null; then
    EXPORT_FAILURES=$((EXPORT_FAILURES + 1))
  fi
done

# Count total files
TOTAL_FILES=$(find "$SCAN_DIR" -type f | wc -l)
echo ""
printf "  ${C_DIM}Total: %d files in %s/${C_RESET}\n\n" "$TOTAL_FILES" "$SCAN_DIR"

if [[ "$TOTAL_FILES" -eq 0 ]]; then
  printf "  ${C_RED}No files exported. Are the VMs running?${C_RESET}\n"
  exit 1
fi

fi  # end of: if ! $SCAN_ONLY

if $EXPORT_ONLY; then
  printf "${C_GREEN}Export complete.${C_RESET} Files in %s/\n" "$SCAN_DIR"
  echo ""
  echo "To scan manually:"
  echo "  cbomkit-theia dir $SCAN_DIR > $CBOM_OUTPUT"
  echo "  # or with Docker:"
  echo "  docker run --rm -v \$(pwd)/$SCAN_DIR:/scan:ro ghcr.io/ibm/cbomkit-theia dir /scan > $CBOM_OUTPUT"
  exit 0
fi

# ── Phase 2: Run cbomkit-theia ──────────────────────────────────────────

printf "${C_CYAN}── Phase 2: Generating CBOM ──${C_RESET}\n\n"

if command -v cbomkit-theia &>/dev/null; then
  printf "  ${C_DIM}Using cbomkit-theia from PATH${C_RESET}\n"
  cbomkit-theia dir "$SCAN_DIR" > "$CBOM_OUTPUT" 2> >(sed 's/^/  /' >&2)
elif docker info &>/dev/null 2>&1; then
  printf "  ${C_DIM}Using cbomkit-theia Docker image${C_RESET}\n"
  docker run --rm \
    -v "$(pwd)/$SCAN_DIR:/scan:ro" \
    ghcr.io/ibm/cbomkit-theia \
    dir /scan > "$CBOM_OUTPUT" 2> >(sed 's/^/  /' >&2)
else
  printf "  ${C_YELLOW}cbomkit-theia not found and Docker not running.${C_RESET}\n"
  echo ""
  echo "  Install cbomkit-theia:"
  echo "    go install github.com/cbomkit/cbomkit-theia@latest"
  echo ""
  echo "  Or start Docker Desktop and re-run this script."
  echo ""
  echo "  Exported files are in $SCAN_DIR/ — scan manually:"
  echo "    cbomkit-theia dir $SCAN_DIR > $CBOM_OUTPUT"
  exit 0
fi

if [[ -f "$CBOM_OUTPUT" ]]; then
  COMPONENTS=$(grep -c '"type"' "$CBOM_OUTPUT" 2>/dev/null || echo "?")
  SIZE=$(du -h "$CBOM_OUTPUT" | cut -f1)
  echo ""
  printf "  ${C_GREEN}CBOM generated:${C_RESET} %s (%s, ~%s components)\n" "$CBOM_OUTPUT" "$SIZE" "$COMPONENTS"
  echo ""
  echo "  View:"
  echo "    cat $CBOM_OUTPUT | python3 -m json.tool | less"
  echo "    # or upload to https://www.zurich.ibm.com/cbom/"
else
  printf "  ${C_RED}CBOM generation failed — check output above${C_RESET}\n"
  exit 1
fi
