# observe_timer

Reusable systemd **timer + oneshot service + optional ingest hook** for
observability probes — the pattern `cloudflare_pqc` proved out (timer fires a
probe on a cadence, `ExecStartPost` pipes the report through `cbom_ingest.py`
so an OSD panel is never silently empty), generalized so other probes don't
hand-roll their own units.

## What it does

For a probe named `observe_timer_name`:

1. Templates `/etc/systemd/system/<name>.service` — a `Type=oneshot` unit that
   runs `observe_timer_exec_start`, then (if `observe_timer_ingest_path` is set)
   pipes that report through `cbom_ingest.py` via a non-fatal `ExecStartPost=-`.
2. Templates `/etc/systemd/system/<name>.timer` — `OnCalendar=` cadence with
   `Persistent=true` so a missed run (host asleep) fires on next boot.
3. Enables + starts the timer.

It does **not** install the probe binary or toolkit, or run the probe at
provision time — the calling role owns staging and the initial run; this role
owns only the recurring-execution + ingest wiring.

## Key variables

| var | required | meaning |
|-----|----------|---------|
| `observe_timer_name` | yes | unit basename (e.g. `cloudflare-pqc`) |
| `observe_timer_description` | yes | `[Unit] Description=` text |
| `observe_timer_exec_start` | yes | command the oneshot runs |
| `observe_timer_oncalendar` | no (`*-*-* 00/6:00:00`) | systemd `OnCalendar=` |
| `observe_timer_user` | no (`root`) | `[Service] User=` |
| `observe_timer_after` | no (`network-online.target`) | ordering |
| `observe_timer_documentation` | no | `Documentation=` URI |
| `observe_timer_ingest_path` | no | report file to feed cbom_ingest.py; unset = no ingest hook |
| `observe_timer_ingest_python` | no (`/usr/bin/python3`) | python used by the ingest hook |
| `observe_timer_ingest_script` | no (`/opt/cbom-toolkit/python/cbom_ingest.py`) | ingest script path |
| `observe_timer_ingest_args` | no (`[]`) | extra args appended to the ingest command |
