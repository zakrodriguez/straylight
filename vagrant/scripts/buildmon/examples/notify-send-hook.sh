#!/bin/bash
# buildmon --on-event reference consumer: desktop notification via notify-send.
# Usage: buildmon.sh -e "$PWD/scripts/buildmon/examples/notify-send-hook.sh" watch
payload=$(cat)
summary=$(python3 -c '
import json, sys
d = json.load(sys.stdin)
who = d.get("vm") or d.get("profile") or "build"
print(f"{d[\"event\"]}: {who}")' <<<"$payload")
command -v notify-send >/dev/null && notify-send "buildmon" "$summary"
