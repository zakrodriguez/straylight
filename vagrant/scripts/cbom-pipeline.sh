#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# cbom-pipeline.sh — CBOM scan → validate → diff → ingest → score pipeline
#
# Usage:
#   bash scripts/cbom-pipeline.sh                     # full pipeline
#   bash scripts/cbom-pipeline.sh --scan-only          # skip export, scan existing data
#   bash scripts/cbom-pipeline.sh --no-ingest          # don't send to OpenSearch
#   bash scripts/cbom-pipeline.sh --scanner theia      # single scanner only
#   bash scripts/cbom-pipeline.sh --no-export          # skip cert export, run scans
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SCRIPT_DIR/.."

# ── Configuration ─────────────────────────────────────────────────────────

# Resolve active profile (sets LAB_PROFILE_NAME, VAGRANT_DOTFILE_PATH).
source "$_SCRIPT_DIR/lib/profile-helper.sh"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
EXPORT_DIR="cbom-export"
OUTPUT_DIR="cbom-output"
BASELINE_DIR="cbom-toolkit/baselines"
TOOLKIT_PY="cbom-toolkit/python"
# OpenSearch :9200 is now loopback-only on observe1. Host-side CBOM tooling
# reaches it through the observe_tls nginx data port (:9244 → TLS + HTTP
# Basic Auth → 127.0.0.1:9200). Credentials come from the env, falling back
# to the active profile's generated group_vars (no hardcoded secrets).
# The Python ingest CLIs read OPENSEARCH_USER / OPENSEARCH_PASS
# automatically; we still pass them in OPENSEARCH_URL-aware tools that don't.
source "$_SCRIPT_DIR/lib/lab-secrets.sh"
# Active profile's /24 (first three octets) for subnet-aware target lists.
# Per-VM lookups use lab_vm_ip; this prefix covers the comma/shorthand lists.
LAB_NET="${LAB_NETWORK:-$(lab_network)}"; LAB_NET="${LAB_NET:-192.168.56}"
OPENSEARCH_URL="${OPENSEARCH_URL:-https://$(lab_groupvar observe_ip):9244}"
export OPENSEARCH_USER="${OPENSEARCH_USER:-beats}"
export OPENSEARCH_PASS="${OPENSEARCH_PASS:-$(lab_groupvar admin_password)}"
# Lab CA isn't in the host's trust store; tools fall back to --insecure here.
CBOM_INGEST_INSECURE="${CBOM_INGEST_INSECURE:---insecure}"

SCANNER_FILTER=""
DO_EXPORT=true
DO_INGEST=true
DO_SCORE=true

# ── Parse args ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan-only)   DO_EXPORT=false; shift ;;
    --no-export)   DO_EXPORT=false; shift ;;
    --no-ingest)   DO_INGEST=false; shift ;;
    --no-score)    DO_SCORE=false; shift ;;
    --scanner)     SCANNER_FILTER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--scan-only] [--no-export] [--no-ingest] [--no-score] [--scanner NAME]"
      echo ""
      echo "Scanners: theia, nmap-network, ejbca-api, all (default: all available)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR" "$BASELINE_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────

log() { echo -e "\033[36m[pipeline]\033[0m $*"; }
ok()  { echo -e "\033[32m[pipeline]\033[0m $*"; }
err() { echo -e "\033[31m[pipeline]\033[0m $*" >&2; }

run_scanner() {
  local scanner_name="$1"
  local output_file="$OUTPUT_DIR/cbom-${scanner_name}-${LAB_PROFILE_NAME}-${TIMESTAMP}.json"
  local deduped_file="$OUTPUT_DIR/cbom-${scanner_name}-${LAB_PROFILE_NAME}-${TIMESTAMP}-deduped.json"
  local baseline_file="$BASELINE_DIR/baseline-${scanner_name}-${LAB_PROFILE_NAME}.json"

  log "━━━ Scanner: $scanner_name ━━━"

  # ── Scan ──
  case "$scanner_name" in
    theia)
      log "Running cbomkit-theia on $EXPORT_DIR/"
      if command -v cbomkit-theia &>/dev/null; then
        cbomkit-theia dir "$EXPORT_DIR" > "$output_file" 2> >(sed 's/^/  /' >&2)
      elif docker image inspect ghcr.io/ibm/cbomkit-theia &>/dev/null 2>&1; then
        docker run --rm -v "$(pwd)/$EXPORT_DIR:/scan:ro" ghcr.io/ibm/cbomkit-theia dir /scan > "$output_file" 2> >(sed 's/^/  /' >&2)
      else
        err "cbomkit-theia not found (neither binary nor Docker image)"
        return 1
      fi
      ;;
    nmap-network)
      log "Running nmap TLS network scan (via scanner1 VM)"
      local scanner_ip="$(lab_vm_ip scanner1)"
      local scanner_key="${VAGRANT_DOTFILE_PATH}/machines/scanner1/virtualbox/private_key"
      local ssh_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -i $scanner_key"
      local nmap_xml="/tmp/nmap-lab-tls-${TIMESTAMP}.xml"
      local targets="${LAB_NET}.10,20,30,50,51,52,53,55,60,100,101"
      local ports="22,80,443,636,3000,3389,5044,5601,8080,8200,8443,8444,9000,9010,9200"

      if ssh $ssh_opts vagrant@"$scanner_ip" "which nmap" &>/dev/null; then
        log "Scanning $targets on ports $ports..."
        ssh $ssh_opts vagrant@"$scanner_ip" "sudo nmap -sV --script ssl-cert,ssl-enum-ciphers -p $ports $targets -oX /tmp/nmap-scan.xml" 2> >(sed 's/^/  /' >&2) || true
        scp $ssh_opts vagrant@"$scanner_ip":/tmp/nmap-scan.xml "$nmap_xml" 2>/dev/null

        # Supplemental: openssl KEX probe for PQC hybrid key exchange groups
        # nmap can't negotiate PQC KEX — openssl 3.5+ (installed to /opt/openssl-3.5) can
        local kex_json="/tmp/kex-probe-${TIMESTAMP}.json"
        local kex_arg=""
        if ssh $ssh_opts vagrant@"$scanner_ip" "test -x /opt/openssl-3.5/bin/openssl" 2>/dev/null; then
          log "Running openssl KEX probe for PQC hybrid groups..."
          # Expand nmap shorthand IPs (${LAB_NET}.10,20,30) to full IPs
          # and probe only known TLS ports to avoid wasting time on non-TLS services
          local kex_tls_ports="443,636,3389,8443,8444,9000,9200"
          local kex_targets=""
          local prefix
          prefix=$(echo "$targets" | grep -oP '^\d+\.\d+\.\d+\.')
          for octet in $(echo "$targets" | tr ',' ' '); do
            local ip
            if [[ "$octet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              ip="$octet"
            else
              ip="${prefix}${octet}"
            fi
            for p in $(echo "$kex_tls_ports" | tr ',' ' '); do
              kex_targets="${kex_targets:+${kex_targets},}${ip}:${p}"
            done
          done
          scp $ssh_opts "$TOOLKIT_PY/kex_probe.py" vagrant@"$scanner_ip":/tmp/kex_probe.py 2>/dev/null
          ssh $ssh_opts vagrant@"$scanner_ip" "OPENSSL_BIN=/opt/openssl-3.5/bin/openssl python3 /tmp/kex_probe.py --targets '$kex_targets' --groups X25519MLKEM768,SecP256r1MLKEM768,MLKEM768 --timeout 3 -o /tmp/kex-probe.json" 2> >(sed 's/^/  /' >&2) || true
          scp $ssh_opts vagrant@"$scanner_ip":/tmp/kex-probe.json "$kex_json" 2>/dev/null && kex_arg="--kex-json $kex_json"
        else
          log "OpenSSL 3.5 not found on scanner1 — skipping PQC KEX probe (provision scanner1 to install)"
        fi

        python3 "$TOOLKIT_PY/nmap_to_cbom.py" "$nmap_xml" $kex_arg -o "$output_file" 2>&1 | sed 's/^/  /'
      else
        err "nmap not available on scanner1 ($scanner_ip)"
        return 1
      fi
      ;;
    ejbca-api)
      log "Querying EJBCA REST API for CA certificates"
      python3 "$TOOLKIT_PY/ejbca_api_to_cbom.py" \
        --ejbca-host "${EJBCA_IP:-$(lab_vm_ip ejbca1)}" \
        --ejbca-key "${VAGRANT_DOTFILE_PATH}/machines/ejbca1/virtualbox/private_key" \
        -o "$output_file" 2>&1 | sed 's/^/  /'
      ;;
    pqc-handshake)
      log "Probing TLS endpoints with OpenSSL 3.5 (detects pure-PQC handshakes)"
      local scanner_ip="$(lab_vm_ip scanner1)"
      local scanner_key="${VAGRANT_DOTFILE_PATH}/machines/scanner1/virtualbox/private_key"
      local ssh_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -i $scanner_key"
      # Lab TLS endpoints worth probing. Pure-PQC endpoints (e.g. observe1:8444)
      # are intentionally invisible to nmap-network — this scanner catches them.
      local probe_targets="${PQC_HANDSHAKE_TARGETS:-${LAB_NET}.53:443,${LAB_NET}.53:8443,${LAB_NET}.53:8444,${LAB_NET}.51:9000,${LAB_NET}.51:9444,${LAB_NET}.50:8443,${LAB_NET}.50:8444,${LAB_NET}.52:8444,${LAB_NET}.30:8443}"
      if ssh $ssh_opts vagrant@"$scanner_ip" "test -x /opt/openssl-3.5/bin/openssl" 2>/dev/null; then
        scp $ssh_opts "$TOOLKIT_PY/pqc_handshake_probe.py" vagrant@"$scanner_ip":/tmp/pqc_handshake_probe.py 2>/dev/null
        ssh $ssh_opts vagrant@"$scanner_ip" "python3 /tmp/pqc_handshake_probe.py --targets '$probe_targets' --summary -o /tmp/pqc-handshake.json" 2> >(sed 's/^/  /' >&2) || true
        scp $ssh_opts vagrant@"$scanner_ip":/tmp/pqc-handshake.json "$output_file" 2>/dev/null
      else
        err "OpenSSL 3.5 not found on scanner1 — provision scanner1 to install"
        return 1
      fi
      ;;
    pqc-openpgp)
      log "Probing OpenPGP keys via GnuPG (detects Kyber-768 PQC subkeys)"
      # Scanner runs on the orchestrator (not on a VM) because it SSHes
      # into each target itself to fetch `gpg --list-keys --with-colons`.
      # gpg-bin / homedir defaults match what gnupg_pqc role installs.
      local pgp_targets="${PQC_OPENPGP_TARGETS:-observe1=${LAB_NET}.53,stepca1=${LAB_NET}.51,ejbca1=${LAB_NET}.50,hydra1=${LAB_NET}.52}"
      python3 "$TOOLKIT_PY/pqc_openpgp_probe.py" \
        --targets "$pgp_targets" \
        --ssh-key-dir "${VAGRANT_DOTFILE_PATH}/machines" \
        --summary -o "$output_file" 2> >(sed 's/^/  /' >&2) || true
      ;;
    pqc-ssh)
      log "Probing SSH KEX algorithms with OpenSSH 10 (detects mlkem768x25519-sha256)"
      # Runs on observe1 because that's where /opt/openssh-10 is. The
      # alternative (build OpenSSH 10 on scanner1) would just duplicate
      # the build. observe1 has 4 PQC SSH endpoints in striking distance.
      local probe_host="$(lab_vm_ip observe1)"
      local probe_key="${VAGRANT_DOTFILE_PATH}/machines/observe1/virtualbox/private_key"
      local ssh_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -i $probe_key"
      # Target list — all four sshd-pqc endpoints by default.
      local ssh_targets="${PQC_SSH_TARGETS:-${LAB_NET}.50:2222,${LAB_NET}.51:2222,${LAB_NET}.52:2222,${LAB_NET}.53:2222}"
      if ssh $ssh_opts vagrant@"$probe_host" "test -x /opt/openssh-10/bin/ssh" 2>/dev/null; then
        scp $ssh_opts "$TOOLKIT_PY/pqc_ssh_probe.py" vagrant@"$probe_host":/tmp/pqc_ssh_probe.py 2>/dev/null
        ssh $ssh_opts vagrant@"$probe_host" "python3 /tmp/pqc_ssh_probe.py --targets '$ssh_targets' --summary -o /tmp/pqc-ssh.json" 2> >(sed 's/^/  /' >&2) || true
        scp $ssh_opts vagrant@"$probe_host":/tmp/pqc-ssh.json "$output_file" 2>/dev/null
      else
        err "OpenSSH 10 not found on observe1 — run pqc-ssh.yml first"
        return 1
      fi
      ;;
    *)
      err "Unknown scanner: $scanner_name"
      return 1
      ;;
  esac

  if [[ ! -s "$output_file" ]]; then
    err "Scanner $scanner_name produced empty output"
    return 1
  fi

  local component_count
  component_count=$(python3 -c "import json; print(len(json.load(open('$output_file')).get('components',[])))" 2>/dev/null || echo "?")
  ok "Scan complete: $component_count components → $output_file"

  # ── Dedup ──
  log "Deduplicating algorithms..."
  cp "$output_file" "$deduped_file"
  python3 scripts/cbom-dedup.py "$deduped_file" 2>&1 | sed 's/^/  /'

  # ── Validate ──
  # Wrapped to survive set -e/pipefail — the intent is to log FAILs, not abort the pipeline.
  log "Validating CBOM..."
  local validate_exit=0
  python3 "$TOOLKIT_PY/cbom_validate.py" "$deduped_file" 2>&1 | sed 's/^/  /' || validate_exit=${PIPESTATUS[0]:-0}
  if [[ "$validate_exit" -ne 0 ]]; then
    err "Validation found FAIL results — review above"
  fi

  # ── Diff against baseline ──
  if [[ -f "$baseline_file" ]]; then
    log "Diffing against baseline..."
    python3 "$TOOLKIT_PY/cbom_diff.py" "$baseline_file" "$deduped_file" 2>&1 | sed 's/^/  /' || true

    # Ingest diff results — emit added/removed as standalone CBOMs and feed
    # them through cbom_ingest with explicit event-type tags so the OSD Drift
    # Detection dashboard has documents to render.
    if [[ "$DO_INGEST" == true ]]; then
      local diff_json
      diff_json=$(python3 "$TOOLKIT_PY/cbom_diff.py" "$baseline_file" "$deduped_file" --json 2>/dev/null || echo '{"changes":[]}')
      local change_count
      change_count=$(echo "$diff_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('changes',[])))" 2>/dev/null || echo "0")
      if [[ "$change_count" -gt 0 ]]; then
        log "Ingesting $change_count diff events to OpenSearch..."
        local added_file="$OUTPUT_DIR/cbom-${scanner_name}-${LAB_PROFILE_NAME}-${TIMESTAMP}-diff-added.json"
        local removed_file="$OUTPUT_DIR/cbom-${scanner_name}-${LAB_PROFILE_NAME}-${TIMESTAMP}-diff-removed.json"
        python3 "$TOOLKIT_PY/cbom_diff.py" "$baseline_file" "$deduped_file" \
          --emit-added "$added_file" --emit-removed "$removed_file" \
          --scanner-hint "$scanner_name" >/dev/null 2>&1 || true
        if [[ -s "$added_file" ]]; then
          local added_count
          added_count=$(python3 -c "import json; print(len(json.load(open('$added_file')).get('components',[])))" 2>/dev/null || echo 0)
          if [[ "$added_count" -gt 0 ]]; then
            python3 "$TOOLKIT_PY/cbom_ingest.py" "$added_file" \
              --scanner "$scanner_name" \
              --opensearch-url "$OPENSEARCH_URL" $CBOM_INGEST_INSECURE \
              --event-type diff-added 2>&1 | sed 's/^/  /' || true
          fi
        fi
        if [[ -s "$removed_file" ]]; then
          local removed_count
          removed_count=$(python3 -c "import json; print(len(json.load(open('$removed_file')).get('components',[])))" 2>/dev/null || echo 0)
          if [[ "$removed_count" -gt 0 ]]; then
            python3 "$TOOLKIT_PY/cbom_ingest.py" "$removed_file" \
              --scanner "$scanner_name" \
              --opensearch-url "$OPENSEARCH_URL" $CBOM_INGEST_INSECURE \
              --event-type diff-removed 2>&1 | sed 's/^/  /' || true
          fi
        fi
      fi
    fi
  else
    log "No baseline found — skipping diff (first run)"
  fi

  # ── Ingest ──
  if [[ "$DO_INGEST" == true ]]; then
    log "Ingesting to OpenSearch..."
    python3 "$TOOLKIT_PY/cbom_ingest.py" "$deduped_file" \
      --scanner "$scanner_name" \
      --opensearch-url "$OPENSEARCH_URL" $CBOM_INGEST_INSECURE 2>&1 | sed 's/^/  /'
  fi

  # ── Score ──
  if [[ "$DO_SCORE" == true ]]; then
    log "PQC readiness score..."
    python3 "$TOOLKIT_PY/cbom_score.py" "$deduped_file" 2>&1 | sed 's/^/  /'
  fi

  # ── Rotate baseline ──
  cp "$deduped_file" "$baseline_file"
  ok "Baseline updated: $baseline_file"
  echo ""
}

# ── Phase 1: Export ───────────────────────────────────────────────────────

if [[ "$DO_EXPORT" == true ]]; then
  log "Phase 1: Exporting crypto artifacts from VMs..."
  bash scripts/cbom-scan.sh --export-only 2>&1 | sed 's/^/  /' || {
    # cbom-scan.sh might not support --export-only yet, run full scan
    log "Running full cbom-scan.sh (export + scan)..."
    bash scripts/cbom-scan.sh 2>&1 | sed 's/^/  /' || true
  }
  echo ""
fi

# ── Phase 2: Run scanners ────────────────────────────────────────────────

log "Phase 2: Running scanners..."

if [[ -n "$SCANNER_FILTER" ]]; then
  run_scanner "$SCANNER_FILTER"
else
  # Run all available scanners
  run_scanner "theia" || true
  run_scanner "nmap-network" || true
  run_scanner "ejbca-api" || true
  run_scanner "pqc-handshake" || true
  run_scanner "pqc-ssh" || true
  run_scanner "pqc-openpgp" || true
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
ok "═══ Pipeline complete ═══"
ok "Output: $OUTPUT_DIR/"
ok "Baselines: $BASELINE_DIR/"
if [[ "$DO_INGEST" == true ]]; then
  ok "Dashboards: http://$(lab_vm_ip observe1):5601/app/dashboards"
fi
