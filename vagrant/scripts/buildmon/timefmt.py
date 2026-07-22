"""ISO-8601 UTC time helpers. Stdlib only."""
from __future__ import annotations
from datetime import datetime, timezone

def iso_utc(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_iso(s: str) -> float:
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()

def dur_s(start_epoch: float, end_epoch: float) -> int:
    return max(0, int(end_epoch - start_epoch))
