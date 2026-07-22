"""Serialize the model to the feed: atomic status.json + append-only events.ndjson."""
from __future__ import annotations
import json
import os
import tempfile
from enums import EVENT_KINDS

class FeedWriter:
    def __init__(self, outdir):
        self.outdir = outdir
        os.makedirs(outdir, exist_ok=True)
        self.status_path = os.path.join(outdir, "status.json")
        self.events_path = os.path.join(outdir, "events.ndjson")

    def write_status(self, snapshot):
        fd, tmp = tempfile.mkstemp(dir=self.outdir, suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(snapshot, fh, separators=(",", ":"))
            # mkstemp creates 0600; the feed is a read contract for other
            # users/tools/agents, so make it world-readable before publishing.
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.status_path)   # atomic
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def append_event(self, event):
        if event.get("kind") not in EVENT_KINDS:
            raise ValueError(f"invalid event kind: {event.get('kind')!r}")
        if "ts" not in event:
            raise ValueError("event missing ts")
        with open(self.events_path, "a") as fh:
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")

    def emit_transitions(self, prev_snapshot, snapshot, ts):
        events = []
        prev_build = (prev_snapshot or {}).get("build", {})
        if prev_build.get("phase") != snapshot["build"]["phase"]:
            events.append({"ts": ts, "kind": "phase",
                           "from": prev_build.get("phase"), "to": snapshot["build"]["phase"]})
        prev_vms = (prev_snapshot or {}).get("vms", {})
        for vm, rec in snapshot["vms"].items():
            pv = prev_vms.get(vm, {})
            if pv.get("state") != rec["state"]:
                events.append({"ts": ts, "vm": vm, "kind": "state",
                               "from": pv.get("state"), "to": rec["state"]})
                if rec["state"] in ("done", "failed", "hung"):
                    events.append({"ts": ts, "vm": vm, "kind": rec["state"] if rec["state"] == "hung" else "done",
                                   "status": 0 if rec["state"] == "done" else 1})
            pt = (pv.get("task") or {}).get("name")
            nt = (rec.get("task") or {}).get("name")
            if nt and nt != pt:
                events.append({"ts": ts, "vm": vm, "kind": "task", "name": nt})
            if rec.get("reboots", 0) > pv.get("reboots", 0):
                events.append({"ts": ts, "vm": vm, "kind": "reboot", "n": rec["reboots"]})
            if rec.get("waiting_on") and rec.get("waiting_on") != pv.get("waiting_on"):
                events.append({"ts": ts, "vm": vm, "kind": "waiting-dep", "on": rec["waiting_on"]})
        for e in events:
            self.append_event(e)
        return events
