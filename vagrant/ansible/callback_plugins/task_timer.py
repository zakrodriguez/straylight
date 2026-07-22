"""Callback plugin: per-task timing with ISO timestamps."""
from __future__ import annotations

import time
from datetime import datetime, timezone

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = """
    name: task_timer
    type: aggregate
    short_description: Per-task timing with ISO timestamps
    description:
        - Shows start time (YYYY-MM-DD HH:MM:SS), per-task elapsed, and
          cumulative playbook time next to each task.
        - Prints a summary of all tasks in execution order at the end.
"""


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "task_timer"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self.play_start = None
        self.task_start = None
        self.task_name = None
        self.tasks = []  # (name, start_time, duration)

    @staticmethod
    def _fmt_seconds(seconds):
        m, s = divmod(int(seconds), 60)
        h, m = divmod(m, 60)
        if h:
            return f"{h:d}:{m:02d}:{s:02d}"
        return f"{m:d}:{s:02d}"

    def _record_task(self):
        if self.task_start is not None and self.task_name is not None:
            duration = time.time() - self.task_start
            self.tasks.append((self.task_name, self.task_start, duration))

    def v2_playbook_on_play_start(self, play):
        if self.play_start is None:
            self.play_start = time.time()

    def v2_playbook_on_task_start(self, task, is_conditional):
        self._record_task()
        now = time.time()
        self.task_start = now
        self.task_name = task.get_name().strip()
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        cumulative = self._fmt_seconds(now - self.play_start) if self.play_start else "0:00"
        self._display.display(f"  {ts}  [{cumulative}]", color="cyan")

    def v2_playbook_on_stats(self, stats):
        self._record_task()
        if not self.play_start:
            return
        total = time.time() - self.play_start

        self._display.display("")
        self._display.display(
            f"Playbook finished: {self._fmt_seconds(total)} total",
            color="bright cyan",
        )
        self._display.display("")
        self._display.display(
            f"  {'Task':<60s} {'Start':>10s}  {'Elapsed':>8s}",
            color="cyan",
        )
        self._display.display(f"  {'─' * 60} {'─' * 10}  {'─' * 8}", color="cyan")
        for name, start, duration in self.tasks:
            ts = datetime.fromtimestamp(start).strftime("%H:%M:%S")
            self._display.display(
                f"  {name:<60s} {ts:>10s}  {self._fmt_seconds(duration):>8s}"
            )
        self._display.display("")
