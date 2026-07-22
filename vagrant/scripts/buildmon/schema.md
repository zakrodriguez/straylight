# Buildmon Feed Schema (buildmon/v1)

The FeedWriter produces the machine contract consumed by external tools and frontends: a snapshot feed (`status.json`) and an event log (`events.ndjson`).

## Location

Both files live under `<logdir>/buildmon/` — for logs at `vagrant/logs/<timestamp>/`, the feed is `vagrant/logs/<timestamp>/buildmon/status.json` and `vagrant/logs/<timestamp>/buildmon/events.ndjson`. The directory also contains `buildmon.log` (the monitor's own diagnostics — not part of the contract). Poll `status.json` for the current snapshot; tail `events.ndjson` for the append-only transition history.

## File Formats

### status.json
Atomic snapshot of build state: a single compact JSON object (`separators=(",", ":")`), rewritten on every status change (or polling interval) via temporary file + rename — never partial.

### events.ndjson
Append-only event log: newline-delimited JSON, one complete object per line, appended sequentially — no seeks, no rewrites, no partial writes.

## Schema Version
All snapshots include `"schema": "buildmon/v1"`.

## status.json Structure

### Root
```json
{
  "schema": "buildmon/v1",
  "build": { ... },
  "vms": { ... }
}
```

### build (object)
Top-level build state.

| Field | Type | Description |
|-------|------|-------------|
| `profile` | string | Lab profile (e.g. "core", "ad-cs-two-tier") |
| `logdir` | string | Path to build logs |
| `phase` | string | Current build phase (enum: PHASES) |
| `started_at` | string (ISO-8601) | UTC timestamp when build started |
| `updated_at` | string (ISO-8601) | UTC timestamp of last update |
| `elapsed_s` | integer | Seconds since build started |
| `counts` | object | Aggregate VM state counts (see below) |

### counts (object)
Tallies of VMs in each state.

| Field | Type | Description |
|-------|------|-------------|
| `total` | integer | Total VMs in topology |
| `pending` | integer | VMs in "pending" state |
| `running` | integer | VMs in a running state (creating/booting/provisioning/rebooting/waiting-dep) |
| `done` | integer | VMs successfully completed |
| `failed` | integer | VMs that failed |
| `hung` | integer | VMs that hung (stalled) |

### vms (object)
Per-VM records, keyed by VM name.

```json
{
  "dc1": { ... },
  "issueca1": { ... }
}
```

#### VM Record

| Field | Type | Description |
|-------|------|-------------|
| `state` | string | Current state (enum: VM_STATES) |
| `role` | string \| null | Ansible role name |
| `vbox` | string | VirtualBox power state (enum: VBOX_STATES) |
| `pid` | integer \| null | Provisioning process ID |
| `pid_alive` | boolean \| null | Whether the known provisioning PID is still running; `null` when no PID is known (normal for a standalone sidecar — see Notes) |
| `elapsed_s` | integer | Seconds since VM start |
| `task` | object \| null | Current task, if any |
| `result` | object \| null | Last task results (if any task has run) |
| `reboots` | integer | Total reboot count this build |
| `stall_s` | integer | Seconds since last observed progress |
| `waiting_on` | string \| null | Short label of the upstream dependency this VM is blocked on (e.g. `"ca1 root cert"`, `"domain join"`) — a dependency description, not necessarily a VM name |
| `guest` | object \| null | Guest-side telemetry (if available) |
| `attempt` | integer \| null | Cross-run provision attempt number for this profile+VM. Present only when > 1. `1 + prior.failed + prior.interrupted`. |
| `prior` | object \| null | `{failed, interrupted}` — counts of prior non-successful runs since this VM's last success (or since a manual `reset-attempts` cutoff). Present only alongside `attempt`. |

`attempt` and `prior` are additive: consumers that don't recognize them can ignore them, their absence (attempt==1, no reprovision history) is backward-compatible, and the schema version stays `buildmon/v1`.

**Note on `pid_alive` and `done`:** a standalone sidecar (`buildmon collect`)
starts with no known provisioning PIDs, so `pid_alive` is `null` for every VM —
expected and normal, not degraded. A clean `PLAY RECAP` (`failed=0`) is the
authoritative completion signal and moves `state` to `"done"` regardless; only a
`pid_alive: true` PID holds a VM back after a clean recap (vagrant is still
finishing up around the process).

#### task (object, if present)

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Task name |
| `started_at` | string (ISO-8601) \| null | When this task started |
| `duration_s` | integer | Seconds elapsed for this task |

#### result (object, if present)

| Field | Type | Description |
|-------|------|-------------|
| `last` | string \| null | Last task result (e.g. "ok", "changed", "failed") |
| `ok` | integer | Count of ok tasks this build |
| `changed` | integer | Count of changed tasks this build |
| `failed` | integer | Count of failed tasks this build |

#### guest (object, if present)

Populated whenever a VM's guest-probe descriptor resolves from inventory (see
`creds.py`); a VM with an unresolvable descriptor (no profile, no inventory
entry, missing SSH key, ...) has no `guest` object at all, not one full of nulls.

| Field | Type | Description |
|-------|------|-------------|
| `reachable` | boolean | Whether guest OS is responding to probes — a plain TCP connect to the VM's SSH/WinRM port, timeout-bounded |
| `last_boot` | string (ISO-8601) | Timestamp of last detected boot — via `uptime -s` over SSH (Linux) or a read-only WinRM WQL query against `Win32_OperatingSystem.LastBootUpTime` (Windows). Always normalized to `YYYY-MM-DDTHH:MM:SS` regardless of source format |
| `pending_reboot` | boolean | Guest reports reboot pending |
| `cpu_pct` | number \| null | Reserved for future guest CPU utilization (0–100); never populated by the current prober — always `null` |
| `mem_pct` | number \| null | Reserved for future guest memory utilization (0–100); never populated by the current prober — always `null` |
| `note` | string \| null | Free-form observation — carries soft-fail reasons (probe timeout, non-zero exit, WinRM auth/transport error, etc.); a `note` without `reachable: true` means the probe couldn't complete, not that the guest is unhealthy |

A `last_boot` advance is one of the signals fused into `"rebooting"` state
derivation and `reboots` counting (alongside VBox power-state edges and TCP
reachability flaps); it lets buildmon recognize a Windows **guest-OS warm
reboot** (domain join, DC promo) even though VirtualBox's power state never
leaves `running` for that kind of restart.

## events.ndjson Structure

Each line is a JSON object with `ts` and `kind` fields. Additional fields depend on the event kind.

### Common Fields (all events)

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string (ISO-8601) | UTC timestamp of event |
| `kind` | string | Event type (enum: EVENT_KINDS) |

### Event Kinds

#### phase
Build phase change.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "phase" |
| `from` | string \| null | Previous phase (null if first) |
| `to` | string | New phase (enum: PHASES) |

#### state
VM state transition.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "state" |
| `vm` | string | VM name |
| `from` | string \| null | Previous state (null if first) |
| `to` | string | New state (enum: VM_STATES) |

#### task
Task started on VM.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "task" |
| `vm` | string | VM name |
| `name` | string | Task name |

#### reboot
VM reboot count increased.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "reboot" |
| `vm` | string | VM name |
| `n` | integer | New reboot count |

#### waiting-dep
VM entered waiting-for-dependency state.

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "waiting-dep" |
| `vm` | string | VM name |
| `on` | string | Name of VM being waited for |

#### done
VM completed successfully (state transitioned to "done" or "failed").

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "done" |
| `vm` | string | VM name |
| `status` | integer | 0 if state=="done", 1 if state=="failed" |

#### hung
VM stalled (state transitioned to "hung").

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "hung" |
| `vm` | string | VM name |
| `status` | integer | 1 |

#### monitor
Internal monitor event (e.g., observation, warning, heartbeat).

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | "monitor" |
| `event` | string | Description or code |

## Enum Vocabularies

### PHASES
Build execution phases.
```
creating | dc1-provision | parallel-provision | done | failed
```

### VM_STATES
Per-VM states during build.
```
pending | creating | booting | provisioning | rebooting | waiting-dep | done | failed | hung
```

### VBOX_STATES
VirtualBox power/state codes.
```
running | poweroff | paused | saved | aborted | unknown
```

### EVENT_KINDS
Feed event types.
```
phase | state | task | reboot | waiting-dep | hung | done | monitor
```

## Timestamp Convention

- All `*_at` fields use ISO-8601 UTC format with `Z` suffix: `"2026-07-01T20:01:00Z"`
- All `*_s` fields are integer seconds (elapsed time or counts).

## Atomicity & Reliability

- **status.json:** written with `tempfile.mkstemp()`, renamed atomically with `os.replace()`; consumers see either the old snapshot or the new one, never partial data.
- **events.ndjson:** one complete `\n`-terminated line per event; appends are not interleaved and no partial JSON objects appear.
- **Ordering:** events are emitted in the order transitions occur within a single `emit_transitions()` call; concurrent snapshots are serialized.
