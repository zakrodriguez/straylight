#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# cbom-orchestrate.sh — Scanner orchestration: schedule, run, and log CBOM
#                       pipeline executions across all scanners.
#
# Usage:
#   bash scripts/cbom-orchestrate.sh                    # one-shot: run full pipeline now
#   bash scripts/cbom-orchestrate.sh --watch 30m        # repeat every 30 minutes
#   bash scripts/cbom-orchestrate.sh --watch 1h         # repeat every hour
#   bash scripts/cbom-orchestrate.sh --scanners theia   # one-shot, single scanner
#   bash scripts/cbom-orchestrate.sh --status           # show last run results
#   bash scripts/cbom-orchestrate.sh --history          # show run history
#   bash scripts/cbom-orchestrate.sh --install-cron 1h  # install systemd timer
#   bash scripts/cbom-orchestrate.sh --remove-cron      # remove systemd timer
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

cd "$(dirname "$0")/.."

# ── Configuration ─────────────────────────────────────────────────────────

LOG_DIR="cbom-output/logs"
HISTORY_FILE="cbom-output/orchestration-history.jsonl"
PIPELINE="scripts/cbom-pipeline.sh"
WATCH_INTERVAL=""
SCANNER_ARG=""
PIPELINE_ARGS=""

mkdir -p "$LOG_DIR"

# ── Parse args ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)      WATCH_INTERVAL="$2"; shift 2 ;;
    --scanners)   SCANNER_ARG="$2"; shift 2 ;;
    --no-ingest)  PIPELINE_ARGS+=" --no-ingest"; shift ;;
    --no-score)   PIPELINE_ARGS+=" --no-score"; shift ;;
    --no-export)  PIPELINE_ARGS+=" --no-export"; shift ;;
    --status)     show_status=true; shift ;;
    --history)    show_history=true; shift ;;
    --install-cron) install_cron="$2"; shift 2 ;;
    --remove-cron)  remove_cron=true; shift ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Run modes:"
      echo "  (no args)           One-shot: run full pipeline now"
      echo "  --watch INTERVAL    Repeat on interval (e.g. 30m, 1h, 6h)"
      echo "  --install-cron INT  Install systemd timer (e.g. 1h)"
      echo "  --remove-cron       Remove systemd timer"
      echo ""
      echo "Options:"
      echo "  --scanners NAME     Run specific scanner (theia, nmap-network)"
      echo "  --no-ingest         Skip OpenSearch ingest"
      echo "  --no-score          Skip PQC scoring"
      echo "  --no-export         Skip cert export from VMs"
      echo ""
      echo "Status:"
      echo "  --status            Show last run results"
      echo "  --history           Show run history (last 20)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────

log()  { echo -e "\033[36m[orchestrate]\033[0m $(date '+%H:%M:%S') $*"; }
ok()   { echo -e "\033[32m[orchestrate]\033[0m $(date '+%H:%M:%S') $*"; }
warn() { echo -e "\033[33m[orchestrate]\033[0m $(date '+%H:%M:%S') $*" >&2; }
err()  { echo -e "\033[31m[orchestrate]\033[0m $(date '+%H:%M:%S') $*" >&2; }

parse_interval() {
  local input="$1"
  local num="${input%[smhd]}"
  local unit="${input: -1}"
  case "$unit" in
    s) echo "$num" ;;
    m) echo $((num * 60)) ;;
    h) echo $((num * 3600)) ;;
    d) echo $((num * 86400)) ;;
    *) echo "$num" ;;
  esac
}

record_run() {
  local status="$1" duration="$2" scanner="${3:-all}" log_file="$4"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "{\"timestamp\":\"$ts\",\"status\":\"$status\",\"duration_s\":$duration,\"scanner\":\"$scanner\",\"log\":\"$log_file\"}" >> "$HISTORY_FILE"
}

# ── Status / History ──────────────────────────────────────────────────────

if [[ "${show_status:-}" == true ]]; then
  if [[ -f "$HISTORY_FILE" ]]; then
    echo ""
    echo "  Last pipeline run:"
    tail -1 "$HISTORY_FILE" | python3 -c "
import json, sys
r = json.loads(sys.stdin.readline())
print(f\"  Time:     {r['timestamp']}\")
print(f\"  Status:   {r['status']}\")
print(f\"  Duration: {r['duration_s']}s\")
print(f\"  Scanner:  {r['scanner']}\")
print(f\"  Log:      {r['log']}\")
"
  else
    echo "  No runs recorded yet."
  fi
  exit 0
fi

if [[ "${show_history:-}" == true ]]; then
  if [[ -f "$HISTORY_FILE" ]]; then
    echo ""
    echo "  Run history (last 20):"
    echo "  ─────────────────────────────────────────────────────────────"
    printf "  %-22s %-8s %8s  %-14s %s\n" "Timestamp" "Status" "Duration" "Scanner" "Log"
    echo "  ─────────────────────────────────────────────────────────────"
    tail -20 "$HISTORY_FILE" | python3 -c "
import json, sys
for line in sys.stdin:
    r = json.loads(line.strip())
    color = '\033[32m' if r['status'] == 'ok' else '\033[31m'
    print(f\"  {r['timestamp']:<22} {color}{r['status']:<8}\033[0m {r['duration_s']:>6}s  {r['scanner']:<14} {r['log']}\")
"
  else
    echo "  No runs recorded yet."
  fi
  exit 0
fi

# ── Install/Remove Cron ──────────────────────────────────────────────────

if [[ "${install_cron:-}" ]]; then
  interval_sec=$(parse_interval "$install_cron")
  script_path="$(cd "$(dirname "$0")" && pwd)/cbom-orchestrate.sh"
  lab_dir="$(cd "$(dirname "$0")/.." && pwd)"

  # Stage the unit files in private temp files (not fixed /tmp paths, which two
  # concurrent users would clobber) and clean them up after the install copy.
  svc_tmp=$(mktemp)
  timer_tmp=$(mktemp)
  trap 'rm -f "$svc_tmp" "$timer_tmp"' EXIT

  cat > "$svc_tmp" << EOF
[Unit]
Description=CBOM Scanner Orchestration Pipeline
After=network.target

[Service]
Type=oneshot
WorkingDirectory=$lab_dir
ExecStart=/bin/bash $script_path
User=$(whoami)
EOF

  cat > "$timer_tmp" << EOF
[Unit]
Description=CBOM Scanner Orchestration Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=${install_cron}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  sudo cp "$svc_tmp" /etc/systemd/system/cbom-orchestrate.service
  sudo cp "$timer_tmp" /etc/systemd/system/cbom-orchestrate.timer
  rm -f "$svc_tmp" "$timer_tmp"
  trap - EXIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now cbom-orchestrate.timer
  ok "Installed systemd timer: runs every $install_cron"
  systemctl status cbom-orchestrate.timer --no-pager
  exit 0
fi

if [[ "${remove_cron:-}" == true ]]; then
  sudo systemctl disable --now cbom-orchestrate.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/cbom-orchestrate.{service,timer}
  sudo systemctl daemon-reload
  ok "Removed systemd timer"
  exit 0
fi

# ── Run Pipeline ──────────────────────────────────────────────────────────

run_pipeline() {
  local run_ts
  run_ts=$(date +%Y%m%d-%H%M%S)
  local log_file="$LOG_DIR/pipeline-${run_ts}.log"
  local scanner_label="${SCANNER_ARG:-all}"

  log "Starting pipeline run (scanner: $scanner_label)"

  local cmd="bash $PIPELINE"
  if [[ -n "$SCANNER_ARG" ]]; then
    cmd+=" --scanner $SCANNER_ARG"
  fi
  cmd+="$PIPELINE_ARGS"

  local start_time
  start_time=$(date +%s)

  if $cmd > "$log_file" 2>&1; then
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    record_run "ok" "$duration" "$scanner_label" "$log_file"
    ok "Pipeline complete (${duration}s) → $log_file"
  else
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    record_run "fail" "$duration" "$scanner_label" "$log_file"
    err "Pipeline failed (${duration}s) — see $log_file"
    tail -20 "$log_file" | sed 's/^/  /'
  fi
}

# ── One-shot or Watch ─────────────────────────────────────────────────────

if [[ -z "$WATCH_INTERVAL" ]]; then
  # One-shot
  run_pipeline
else
  # Watch mode
  interval_sec=$(parse_interval "$WATCH_INTERVAL")
  log "Watch mode: running every ${WATCH_INTERVAL} (${interval_sec}s)"
  log "Press Ctrl+C to stop"
  echo ""

  # Concurrency guard: if a pipeline run outlasts the interval (or another
  # watcher is already running), skip this tick rather than overlap. flock -n
  # takes the lock non-blockingly; failure to acquire means a run is in flight.
  WATCH_LOCK="$LOG_DIR/.orchestrate-watch.lock"

  while true; do
    if flock -n 9; then
      run_pipeline
      flock -u 9
    else
      warn "Previous pipeline run still in progress — skipping this tick"
    fi 9>"$WATCH_LOCK"
    log "Next run in ${WATCH_INTERVAL}..."
    sleep "$interval_sec"
  done
fi
