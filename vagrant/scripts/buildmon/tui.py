"""Feed renderer. render_plain() is pure/testable; run() drives curses or plain output."""
from __future__ import annotations
import json
import os
import sys
import time
import timefmt

def load_feed(logdir):
    outdir = os.path.join(logdir, "buildmon")
    snap = None
    sp = os.path.join(outdir, "status.json")
    if os.path.isfile(sp):
        try:
            with open(sp) as f:
                snap = json.load(f)
        except (ValueError, OSError):
            snap = None
    events = []
    ep = os.path.join(outdir, "events.ndjson")
    if os.path.isfile(ep):
        try:
            with open(ep) as f:
                lines = f.read().strip().splitlines()[-10:]
        except OSError:
            lines = []
        for l in lines:
            if l.strip():
                try:
                    events.append(json.loads(l))
                except ValueError:
                    continue
    return snap, events

def _attempt_suffix(r):
    n = r.get("attempt", 1)
    if n <= 1:
        return ""
    prior = r.get("prior") or {}
    parts = []
    if prior.get("failed"):
        parts.append(f"{prior['failed']} failed")
    if prior.get("interrupted"):
        parts.append(f"{prior['interrupted']} interrupted")
    return f"  (attempt {n}: {', '.join(parts)})" if parts else f"  (attempt {n})"

def render_plain(snapshot, events_tail, now_epoch=None):
    if not snapshot:
        return "buildmon: waiting for feed…"
    b = snapshot["build"]; c = b["counts"]
    lines = []
    header = f"BUILD {b['profile']}  phase={b['phase']}  elapsed={b['elapsed_s']}s  " \
             f"updated={b['updated_at']}"
    if now_epoch is not None and "updated_at" in b:
        try:
            age = max(0, int(now_epoch - timefmt.parse_iso(b["updated_at"])))
            header += f"  (age {age}s)"
        except (ValueError, TypeError):
            pass
    lines.append(header)
    lines.append(f"  {c.get('done',0)}/{c.get('total',0)} done  "
                 f"running={c.get('running',0)} pending={c.get('pending',0)} "
                 f"failed={c.get('failed',0)} hung={c.get('hung',0)}")
    lines.append("")
    lines.append(f"{'VM':<10} {'STATE':<13} {'TASK':<44} {'DUR':>4} {'RES':<8} {'GUEST':<5} reboots stall wait")
    for vm, r in snapshot["vms"].items():
        task = (r.get("task") or {}).get("name") or "-"
        dur = (r.get("task") or {}).get("duration_s")
        res = (r.get("result") or {}).get("last") or "-"
        guest = r.get("guest")
        guest_str = "-" if guest is None else ("up" if guest.get("reachable") else "down")
        terminal = r["state"] in ("done", "failed", "hung")
        # dur/stall keep growing in the raw feed after a VM finishes (time since
        # last log write) — meaningless to a human, so blank them once terminal.
        dur_str = "-" if (terminal or dur is None) else f"{dur}s"
        stall_str = "-" if terminal else str(r.get("stall_s", 0))
        lines.append(f"{vm:<10} {r['state']:<13} {task[:44]:<44} "
                     f"{dur_str:>4} {res:<8} {guest_str:<5} "
                     f"{r.get('reboots',0):>7} {stall_str:>5} {r.get('waiting_on') or '-'}"
                     f"{_attempt_suffix(r)}")
    lines.append("")
    lines.append("recent events:")
    for e in events_tail[-8:]:
        lines.append(f"  {e.get('ts','')}  {e.get('vm','')} {e['kind']} "
                     f"{e.get('to') or e.get('name') or e.get('on') or ''}")
    return "\n".join(lines)

def run(logdir, interval_s=2, plain=False, once=False):
    use_curses = (not plain) and sys.stdout.isatty()
    if not use_curses:
        while True:
            snap, evs = load_feed(logdir)
            sys.stdout.write("\x1b[2J\x1b[H" if not once else "")
            print(render_plain(snap, evs, now_epoch=time.time()))
            if once:
                return 0
            time.sleep(interval_s)
    import curses
    def _loop(stdscr):
        curses.curs_set(0); stdscr.nodelay(True)
        while True:
            snap, evs = load_feed(logdir)
            stdscr.erase()
            for i, line in enumerate(render_plain(snap, evs, now_epoch=time.time()).splitlines()):
                try:
                    stdscr.addstr(i, 0, line[:curses.COLS - 1])
                except curses.error:
                    pass
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (ord("q"), 27):
                return 0
            time.sleep(interval_s)
    return curses.wrapper(_loop)
