"""Injectable clock so stall/duration/replay tests are deterministic."""
from __future__ import annotations
import time as _time

class Clock:
    def now(self) -> float:
        return _time.time()
    def sleep(self, seconds: float) -> None:
        _time.sleep(seconds)

class FakeClock:
    def __init__(self, start: float = 0.0):
        self._t = float(start)
    def now(self) -> float:
        return self._t
    def sleep(self, seconds: float) -> None:
        self._t += float(seconds)
    def advance(self, seconds: float) -> None:
        self._t += float(seconds)
