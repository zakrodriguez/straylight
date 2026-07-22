"""Parse a per-VM ansible/vagrant log into a LogState. Mirrors up.sh."""
from __future__ import annotations
import os
import re
from dataclasses import dataclass

TASK_RE = re.compile(r"TASK \[([^\]]+)\]")
RESULT_RE = re.compile(r"^(ok|changed|skipping|fatal|included|failed):")
RECAP_FAILED_RE = re.compile(r"^\S+\s+: .*failed=(\d+)")
RECAP_HEADER_RE = re.compile(r"^PLAY RECAP")
# Note: read() also treats recap_failed > 0 as fatal-finish; Ansible's recap splits the header and per-host failed= line
FATAL_FINISH_RE = re.compile(r"Ansible failed to complete successfully|PLAY RECAP.*failed=[1-9]")

@dataclass
class LogState:
    task_name: str | None = None
    last_result: str | None = None
    ok: int = 0
    changed: int = 0
    failed: int = 0
    recap_failed: int | None = None
    fatal_finish: bool = False
    mtime_epoch: float | None = None
    exists: bool = False

class LogTailer:
    def __init__(self, path, clock):
        self.path = path
        self.clock = clock

    def read(self) -> LogState:
        st = LogState()
        if not os.path.isfile(self.path):
            return st
        st.exists = True
        try:
            st.mtime_epoch = os.stat(self.path).st_mtime
        except OSError:
            st.mtime_epoch = None
        last_task = None
        last_result = None
        recap_failed = None
        fatal = False
        after_recap = False
        with open(self.path, "r", errors="replace") as fh:
            for line in fh:
                mt = TASK_RE.search(line)
                if mt:
                    # A TASK after a PLAY RECAP means a NEW attempt was
                    # appended to the same log (in-place `vagrant provision`
                    # rerun). The last attempt wins: reset the attempt-scoped
                    # signals so an earlier attempt's fatal markers can't
                    # shadow a later clean recap (false hung/failed — #214).
                    if after_recap:
                        after_recap = False
                        fatal = False
                        recap_failed = None
                        last_result = None
                        st.ok = st.changed = st.failed = 0
                    last_task = mt.group(1)
                mr = RESULT_RE.match(line)
                if mr:
                    last_result = mr.group(1)
                    # Tally result markers
                    if last_result == "ok":
                        st.ok += 1
                    elif last_result == "changed":
                        st.changed += 1
                    elif last_result in ("fatal", "failed"):
                        st.failed += 1
                if FATAL_FINISH_RE.search(line):
                    fatal = True
                if RECAP_HEADER_RE.match(line):
                    after_recap = True
                mrecap = RECAP_FAILED_RE.match(line)
                if mrecap:
                    recap_failed = int(mrecap.group(1))
                    # If we found a failed count in the recap, this is a fatal finish
                    if recap_failed > 0:
                        fatal = True
        st.task_name = last_task
        st.last_result = last_result
        st.recap_failed = recap_failed
        st.fatal_finish = fatal
        return st
