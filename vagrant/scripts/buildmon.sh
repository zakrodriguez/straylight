#!/usr/bin/env bash
# buildmon.sh — one-command launcher for the buildmon build-observability sidecar.
#
# Usage:
#   buildmon.sh [options]           start the collector (if not already running)
#                                   on the selected build and open the live TUI
#   buildmon.sh [options] start     start the collector only, detached (no TUI)
#   buildmon.sh [options] status    one-shot plain snapshot (script/agent friendly)
#   buildmon.sh [options] tail      follow the event stream (events.ndjson)
#   buildmon.sh [options] stop      stop the collector for the selected logdir
#   buildmon.sh list                overview of recent builds: logdir, profile,
#                                   phase, feed state
#   buildmon.sh reset-attempts      reset cross-run attempt counters for a
#                                   profile (requires -p, or infers from the
#                                   newest logdir)
#
# Options:
#   -l LOGDIR   build log directory (default: newest build dir under vagrant/logs/ —
#               skips validate-only dirs and the ansible.log file)
#   -p PROFILE  lab profile. Selects the newest build MATCHING this profile when
#               several builds run simultaneously, and is passed to the collector
#               (which otherwise infers the profile from the logdir contents)
#   -e CMD      alert hook: exec CMD with JSON event on stdin (also: BUILDMON_ON_EVENT)
#   -h          this help
#
# Multi-lab: several builds can run at once — each subcommand targets exactly one
# logdir. With neither -l nor -p, the newest build wins and the others are noted.
#
# The collector is launched detached (setsid); it survives terminal close and is
# strictly read-only against the build. Its console output goes to
# <logdir>/buildmon/collector-console.log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../vagrant/scripts
BM="$HERE/buildmon/__main__.py"
LOGS_ROOT="$HERE/../logs"

usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

logdir=""
profile="${LAB_PROFILE:-}"
on_event=""
while getopts ":l:p:e:h" opt; do
  case "$opt" in
    l) logdir="$OPTARG" ;;
    p) profile="$OPTARG" ;;
    e) on_event="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
cmd="${1:-watch}"

list_args=(list --logs-root "$LOGS_ROOT")
[[ -n "$profile" ]] && list_args+=(--profile "$profile")

if [[ "$cmd" == "list" ]]; then
  exec python3 "$BM" "${list_args[@]}"
fi

if [[ "$cmd" == "reset-attempts" ]]; then
  reset_args=(reset-attempts --logs-root "$LOGS_ROOT")
  [[ -n "$profile" ]] && reset_args+=(--profile "$profile")
  exec python3 "$BM" "${reset_args[@]}"
fi

if [[ -z "$logdir" ]]; then
  # Newest BUILD logdir (validate-only dirs and plain files like ansible.log are
  # skipped; with -p, only builds whose VM set fits that profile qualify).
  builds=(); live=()
  while IFS=$'\t' read -r d _ _ feed _; do
    # `dead-*` dirs are operator-marked corpses (renamed after a failed run).
    # Never auto-select one — during the 2026-07-06 three-lab session both
    # the bare default (newest mtime) and `-p pqc-full` matching kept landing
    # on a dead dir, whose feed then mixed stale log state with live guest
    # probes of the current build's same-named VMs (#210). Explicit -l still
    # targets them.
    [[ "$(basename "$d")" == dead-* ]] && continue
    builds+=("$d")
    [[ "$feed" == "live" ]] && live+=("$d")
  done < <(python3 "$BM" "${list_args[@]}" --porcelain 2>/dev/null)
  logdir="${builds[0]:-}"
  if [[ -z "$logdir" ]]; then
    echo "buildmon.sh: no build logdir found${profile:+ for profile $profile} (looked in $LOGS_ROOT); use -l LOGDIR" >&2
    exit 2
  fi
  # Multi-lab: only builds with a LIVE feed are worth flagging — old completed
  # logdirs always exist and are not "another build running".
  others=""
  for b in "${live[@]}"; do
    [[ "$b" == "$logdir" ]] || others+="${others:+, }$(basename "$b")"
  done
  if [[ -n "$others" ]]; then
    echo "note: using newest build $(basename "$logdir") — other live builds: $others" >&2
    echo "      Pick one with -l LOGDIR or -p PROFILE; overview: buildmon.sh list" >&2
  fi
fi
if [[ ! -d "$logdir" ]]; then
  echo "buildmon.sh: $logdir is not a directory; use -l LOGDIR" >&2
  exit 2
fi
logdir="$(cd "$logdir" && pwd)"   # absolute, no trailing slash

collector_pids() { pgrep -f -- "__main__.py collect --logdir $logdir" || true; }

start_collector() {
  local pids
  pids="$(collector_pids)"
  # A `stopping` marker means a previous collector was TERM'd and is still
  # flushing its final snapshot (guest probes across every VM — can exceed
  # 30s). Wait for it to exit instead of no-op'ing with "already running";
  # without this, stop→start back-to-back silently kept the old collector
  # (raced live 2026-07-06 during #210 remediation).
  if [[ -n "$pids" && -f "$logdir/buildmon/stopping" ]]; then
    echo "previous collector (PID ${pids//$'\n'/, }) is flushing — waiting for it to exit..."
    for _ in $(seq 1 120); do
      pids="$(collector_pids)"
      [[ -z "$pids" ]] && break
      sleep 0.5
    done
  fi
  if [[ -n "$pids" ]]; then
    echo "collector already running for $logdir (PID ${pids//$'\n'/, })"
    return 0
  fi
  mkdir -p "$logdir/buildmon"
  rm -f "$logdir/buildmon/stopping"
  local args=(collect --logdir "$logdir")
  [[ -n "$profile" ]] && args+=(--profile "$profile")
  [[ -n "$on_event" ]] && args+=(--on-event "$on_event")
  setsid nohup python3 "$BM" "${args[@]}" \
    >> "$logdir/buildmon/collector-console.log" 2>&1 < /dev/null &
  sleep 1
  pids="$(collector_pids)"
  if [[ -z "$pids" ]]; then
    echo "buildmon.sh: collector failed to start — see $logdir/buildmon/collector-console.log" >&2
    exit 1
  fi
  echo "collector started for $logdir (PID ${pids//$'\n'/, }${profile:+, profile $profile})"
}

case "$cmd" in
  watch)
    start_collector
    exec python3 "$BM" watch --logdir "$logdir"
    ;;
  start)
    start_collector
    ;;
  status)
    if [[ ! -f "$logdir/buildmon/status.json" ]]; then
      echo "no feed yet for $logdir — start the collector: buildmon.sh -l $logdir" >&2
      exit 1
    fi
    exec python3 "$BM" watch --logdir "$logdir" --once --plain
    ;;
  tail)
    if [[ ! -f "$logdir/buildmon/events.ndjson" ]]; then
      echo "no feed yet for $logdir — start the collector: buildmon.sh -l $logdir" >&2
      exit 1
    fi
    exec tail -f "$logdir/buildmon/events.ndjson"
    ;;
  stop)
    pids="$(collector_pids)"
    if [[ -z "$pids" ]]; then
      echo "no collector running for $logdir"
    else
      # Mark shutdown intent BEFORE signalling: the graceful-shutdown
      # handler runs a final collection pass (guest probes across every VM)
      # that can exceed 30s, so a fixed post-kill wait can't reliably cover
      # it. `start` sees this marker and waits for the dying PID instead of
      # no-op'ing with "already running".
      touch "$logdir/buildmon/stopping" 2>/dev/null || true
      # shellcheck disable=SC2086
      kill -TERM $pids
      for _ in $(seq 1 60); do
        [[ -z "$(collector_pids)" ]] && break
        sleep 0.5
      done
      if [[ -n "$(collector_pids)" ]]; then
        echo "collector (PID ${pids//$'\n'/, }) is still flushing its final snapshot — a subsequent start will wait for it" >&2
      else
        rm -f "$logdir/buildmon/stopping"
        echo "stopped collector (PID ${pids//$'\n'/, }) — final snapshot flushed"
      fi
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
