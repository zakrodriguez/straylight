# buildmon

A standalone, Python-stdlib-only build-observability sidecar for Straylight lab builds.

## What it is

During a lab build (`vagrant/up.sh` + Vagrant + Ansible), Phase 3 shows per-Ansible-task
progress (task, ok/changed/fatal) via `print_vm_status`, but Phase 2's overlap-wait skips
dc1 (`[[ "$vm" == "dc1" ]] && continue`): through the multi-minute forest promo the
operator sees only `dc1 waiting on background PID <pid>… [Xm]`, though the task info
exists in `logs/<ts>/dc1.log`. Also untapped: VBox power state / reboot transitions (a
reboot looks identical to a stall), current-task duration vs. total elapsed, cross-VM
dependency-waits (e.g. web1 parked on "Wait for Root CA cert"), and guest-side state.

buildmon aggregates all of these — per-VM log tailing (task name, result tallies,
duration, staleness), VBox power-state polling with reboot detection, phase and
dependency-wait derivation, and optional safe read-only guest probes — into one decoupled
feed; dc1 is just another tailed VM, present in every phase. A curses TUI
(`buildmon watch`) and `status.json` readers consume the feed independently; the collector
and renderer never talk to each other directly.

## Usage

**Default path — nothing to start:** `vagrant/up.sh` auto-attaches the collector to every
build it launches (`LAB_BUILDMON=off` opts out), so a normal build already has a live
feed; open the TUI with `vagrant/scripts/buildmon.sh`.

**Manual / alternative — the launcher:** `buildmon.sh` starts the collector on the newest
build (idempotently — a no-op when up.sh already attached one) and opens the TUI;
`buildmon.sh start|status|tail|stop|list|reset-attempts` cover the rest — `list` shows
recent build logdirs (newest first) with profile, phase, and feed state, whether or not a
collector is running; `reset-attempts` resets cross-run attempt counters for a profile;
`-p PROFILE` selects the newest build matching that profile. The manual form the launcher
wraps runs from `vagrant/scripts/` (internal modules are flat imports resolved relative
to the `buildmon` package directory):

```bash
cd vagrant/scripts

# Start the collector sidecar against a build's log directory.
python3 -m buildmon collect --logdir ../logs/<ts> --profile core &

# In another terminal / pane, render the live feed as a TUI.
python3 -m buildmon watch --logdir ../logs/<ts>
```

From any other directory, invoke the entrypoint by path instead of `-m`:

```bash
python3 ~/straylight/vagrant/scripts/buildmon/__main__.py collect --logdir <abs-logdir> --profile core
```

CLI guards: `--logdir` must be a build's log *directory* (`vagrant/logs/<timestamp>/`; a
plain `ls -t vagrant/logs | head -1` wrongly returns `ansible.log`, always the newest
entry during a build); a wrong `--profile` is warned and self-healed (the collector
adopts VM logs appearing in the logdir — though with a known profile, a log stem that is
neither one of that profile's components nor backed by a `<vm>-create.log` is ignored as
a helper log, not a VM).

`collect` runs until killed; SIGINT/SIGTERM stop it cleanly, flushing a final snapshot and
a `monitor:stopped` event. It need not start before the build, and stopping it never
affects the build in progress (see Guarantees below).

### `collect` options

| Flag | Default | Meaning |
|------|---------|---------|
| `--logdir` | (required) | Build log directory, e.g. `logs/20260701-152947` |
| `--profile` | inferred | Lab profile name (e.g. `core`, `pqc-full`); resolves VM set/order from `vagrant/profiles/<profile>.yml`. When omitted, buildmon **infers** it from the logdir's VM logs (see Multi-lab below), then falls back to the log files themselves, then to registered VBox machine names |
| `--interval` | 5 | Seconds between collector ticks |
| `--hang-detect` | 600 | Seconds of no observed progress before a VM whose log carries a fatal-finish marker is marked `hung` (with progress it is `failed` instead); a quiet log alone never marks a VM `hung` |
| `--no-guest-probe` | off | Disable guest probing even when credentials resolve from inventory |
| `--profiles-dir` | auto | Override where `<profile>.yml` is looked up |
| `--on-event` | none | Host command exec'd with one JSON event on stdin on `vm_failed`/`vm_hung`/`build_done`/`build_failed`; env fallback `BUILDMON_ON_EVENT`. See "Alert hook" below |

### `watch` options

| Flag | Default | Meaning |
|------|---------|---------|
| `--logdir` | (required) | Same log directory passed to `collect` |
| `--interval` | 2 | Seconds between redraws |
| `--plain` | off | Render one plain-text table instead of the curses UI (useful for logging / CI / non-tty) |
| `--once` | off | Render a single frame and exit (combine with `--plain` for scripting) |

### `list` options

`buildmon list --logs-root vagrant/logs` prints recent **build** logdirs newest first
(validate-only dirs skipped) with each build's profile (from its feed if a collector ran,
else inferred), phase, and feed freshness (`live`/`stale`/`none`). `--profile X` restricts
to builds whose VM set fits that profile; `--porcelain` emits tab-separated rows (used by
the launcher for logdir selection); `--limit N` caps output (default 10).

## Multiple simultaneous builds (multi-lab)

Several labs can build at once (separate logdirs, dotfiles, subnets); buildmon runs **one
collector per logdir**, so feeds never mix. VM stems recur across profiles (8 of the 14
lab profiles have a `dc1`), so VBox machines are only distinguishable by profile prefix
(`straylight-<profile>-<vm>`); buildmon handles this by:

- **Profile inference.** Without `--profile`, the collector infers it from the logdir's VM
  logs — `<vm>-create.log` appears for every VM within seconds of Phase 1. An exact
  component-set match wins only when no other profile is a strict superset of the observed
  stems, or once the create phase has settled (newest create-log ≥ 180 s old) — until
  then a partially-created larger lab can exactly impersonate a smaller one. Ties (e.g.
  `core` vs `ad-cs-one-tier`, which share a VM set) go to the single profile with
  registered VBox machines for every observed VM; if still ambiguous, it re-infers on
  each newly adopted VM log and periodically between adoptions. It never guesses — a
  wrong profile would plant phantom VMs.
- **Create-log VM resolution.** The VM set resolves from `<vm>-create.log` + `<vm>.log`
  stems, so Phase 1 shows every VM as `pending`/`booting` instead of falling back to
  registered VBox machines, which would mix in every registered lab's VMs.
- **Per-build selection in the launcher.** `buildmon.sh` targets one logdir per
  invocation: `-l LOGDIR` picks it explicitly, `-p PROFILE` picks the newest build whose
  VMs fit that profile, and with neither the newest build wins (other builds with live
  feeds are noted on stderr).

## The feed

`collect` writes into `<logdir>/buildmon/`:

- **`status.json`** — atomic snapshot of current build state (poll this). Written via
  `tempfile.mkstemp()` + `os.replace()`, so readers never see a partial write.
- **`events.ndjson`** — append-only newline-delimited transition log (tail this), one
  complete JSON object per line: phase changes, VM state transitions, task starts,
  reboots, dependency-waits, done/failed, hung.
- **`buildmon.log`** — the collector's own diagnostics (source failures, notes); not part
  of the machine contract, don't parse it.

Full field-by-field schema, enum vocabularies, and atomicity guarantees:
**[`schema.md`](schema.md)**.

## Guarantees: observer-only, safe by construction

buildmon never drives or mutates the build:

- **No `vagrant` or `ansible` invocations, anywhere.** A static test
  (`tests/test_noninvasive.py`) greps the collector/vbox/guest sources for those tokens
  and fails the suite if either appears.
- **VBox access is read-only.** `vbox.py`'s default runner allows only the `list` and
  `showvminfo` verbs; any mutating verb (`controlvm`, `startvm`, ...) raises immediately.
- **Guest probes are allowlisted and read-only** — `cat /proc/loadavg`, `uptime -s`,
  `systemctl is-active winrm` (SSH) / a single read-only WSMan query for
  `Win32_OperatingSystem.LastBootUpTime` (WinRM). No other command can be constructed or
  run. (The feed's `pending_reboot` field is declared but not implemented — no probe
  ever sets it.)
- **Guest probes never raise into the host loop.** Timeouts, connection errors, and
  non-zero exits soft-fail into a `note` field; `GuestProbePool` runs one isolated thread
  per VM behind a concurrency cap with backoff, so one hung or broken probe can't affect
  another VM or the collector's main tick.
- **Every collector source is wrapped defensively** (`Collector._safe`): a throw in log
  tailing, VBox polling, or guest probing for one VM on one tick degrades that source to
  a safe default; the tick continues.
- **Killing the collector is always safe.** It owns or gates no part of the build;
  `up.sh`/Vagrant/Ansible proceed identically whether buildmon is running or not.

## Guest probing: automatic, credential-free to configure

`GuestProber` and `GuestProbePool` resolve SSH/WinRM connection facts from the profile's
rendered Ansible inventory (`ansible/inventory/<profile>/static.ini` — the same facts
Ansible itself uses), so nothing is configured per VM. `collect` builds a `GuestProber`
for every VM whose descriptor resolves and enables the pool whenever at least one does;
`--no-guest-probe` opts out. A VM with no resolvable descriptor (no `--profile`, no
inventory entry, missing SSH key, ...) is logged and stays dark — its `guest` field in
`status.json` is absent/`null` — without blocking the host-side feed.

## Alert hook

`collect --on-event CMD` (or env `BUILDMON_ON_EVENT`) execs `CMD` once per qualifying
transition with a single JSON object piped to its stdin — fire and forget,
timeout-bounded, never fatal to the collector if the hook fails or hangs. Events fire once
per (event, vm) per collector run (no re-firing on flapping states):

- `vm_failed` / `vm_hung` — a VM transitions into `failed`/`hung` state
- `build_done` / `build_failed` — the overall build phase transitions to `done`/`failed`

Payload shape:

```json
{"event": "vm_failed", "vm": "dc1", "ts": "2026-07-06T12:00:00Z",
 "profile": "core", "logdir": "/path/to/logs/<ts>", "state": "failed",
 "attempt": 1}
```

(`build_done`/`build_failed` payloads have `"vm": null` instead of a VM name.)

The launcher passes this through as `-e CMD` (run from `vagrant/`):

```bash
scripts/buildmon.sh -e "$PWD/scripts/buildmon/examples/notify-send-hook.sh" watch
```

A minimal reference consumer — a desktop notification via `notify-send` — is at
[`examples/notify-send-hook.sh`](examples/notify-send-hook.sh).

## How agents/tools consume `status.json`

`status.json` is a single compact JSON object, fully replaced on every write — safe to
poll, no partial-read races. A minimal consumer:

```python
import json

d = json.load(open("logs/<ts>/buildmon/status.json"))
print("phase:", d["build"]["phase"])
print("per-VM state:", {vm: v["state"] for vm, v in d["vms"].items()})

dc1 = d["vms"].get("dc1", {})
print("dc1 current task:", (dc1.get("task") or {}).get("name"))
print("dc1 result tallies:", dc1.get("result"))
```

Useful fields for automation: `build.phase`, `build.counts` (aggregate
done/failed/hung/running tallies), and per-VM `state`, `task.name`, `task.duration_s`,
`stall_s` (staleness), `waiting_on` (dependency blocking), `reboots`; full structure in
[`schema.md`](schema.md). `events.ndjson` is the append-only companion for timeline
consumers — e.g. watching for a VM's first `"kind": "hung"` or `"kind": "done"` event.

### `done` works without PIDs; `pid_alive` is honest about what's known

`cli.py` constructs the `Collector` with `pid_map={}`, but the collector reads
`<logdir>/<vm>.pid` every tick — up.sh writes that pidfile when it backgrounds each VM's
provision job, so any build launched by up.sh has known PIDs even for a collector attached
late. A build launched without up.sh (bare `vagrant up`) writes no pidfiles and
`pid_alive` stays `null`. `state` reaches `"done"` either way once a VM's log shows a
clean `PLAY RECAP` (`failed=0`), the authoritative completion signal. `pid_alive` in
`status.json` is `true`/`false`/`null`; `null` never blocks `"done"`; only
`pid_alive: true` holds a VM at `"provisioning"` after a clean recap, since vagrant may
still be finishing up around that process.

`"rebooting"` is PID-gated (the full-restart path requires
`vbox in (poweroff, saved) and pid_alive`; the warm-reboot path below also requires
`pid_alive`), so it is reachable whenever up.sh pidfiles are present — unreachable only
for a build without them. Reboot **counting** (`reboots`) and `"kind": "reboot"` events
from VBox power-state edge detection work regardless of PIDs.

**Caveat: VBox-detected reboots are full-VM restarts only.** VirtualBox reports a
`poweroff → running` edge only for full VM restarts (e.g. `vagrant reload`); Windows
**guest-OS warm reboots** — as during domain join or DC promo — keep `VMState=running`, so
the host-side poller alone does not count them. State derivation takes no guest input:
the warm-reboot `"rebooting"` state comes from the log + PID heuristic alone (a
reboot-pattern task whose log has been quiet ≥ 30 s while the provision PID is alive and
VBox still reports `running`). Guest signals drive only the reboots **count**: within a
rebooting window an advancing guest-probe `last_boot` or a reachability flap counts the
reboot; outside a window an advancing `last_boot` counts once per distinct value. With no
resolvable guest descriptor a warm reboot goes uncounted and surfaces only as the
`"rebooting"` state / a quiet log window (`stall_s` climbing with no new task).
