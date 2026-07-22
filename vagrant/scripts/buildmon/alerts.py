"""Pluggable alert hook: exec a user command with one JSON event on stdin.

The hook is the user's explicit opt-in (--on-event CMD / BUILDMON_ON_EVENT)
and runs on the HOST. Fire-and-forget with a timeout; every failure is soft
— an alert must never take the collector down. One firing per (event, vm)
per collector run so flapping states don't spam.
"""
from __future__ import annotations
import json
import subprocess
import threading
import time


def _default_runner_factory(timeout_s, logger):
    def _run(cmd, payload):
        def _target():
            try:
                p = subprocess.run(cmd, shell=True, input=payload,
                                   capture_output=True, text=True,
                                   timeout=timeout_s)
                if p.returncode != 0 and logger:
                    logger(f"alert hook rc={p.returncode}: {(p.stderr or '').strip()[:120]}")
            except Exception as exc:
                if logger:
                    logger(f"alert hook error: {exc!r}")
        threading.Thread(target=_target, daemon=True).start()
    return _run


class AlertDispatcher:
    def __init__(self, cmd, runner=None, logger=None, timeout_s=10):
        self.cmd = cmd or None
        self.logger = logger
        self.runner = runner or _default_runner_factory(timeout_s, logger)
        self._fired = set()

    def dispatch(self, event, vm, payload_extra):
        if not self.cmd:
            return False
        key = (event, vm)
        if key in self._fired:
            return False
        try:
            payload = json.dumps({"event": event, "vm": vm,
                                  "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                  **(payload_extra or {})})
            self._fired.add(key)
            self.runner(self.cmd, payload)
        except Exception as exc:
            try:
                if self.logger:
                    self.logger(f"alert dispatch error: {exc!r}")
            except Exception:
                pass
            return key in self._fired
        return True
