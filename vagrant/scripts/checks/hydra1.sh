#!/bin/bash
# scripts/checks/hydra1.sh — extracted from validate.sh verbatim.
register_checks_hydra1() {
# ─── HYDRA1 ────────────────────────────────────────────────────────────

if is_running hydra1; then
    launch_check hydra1 run_linux_check hydra1 "$(cat <<'BASH'
for ctr in hydra-postgres hydra hydra-consent; do
    running=$(docker ps --filter name="^${ctr}$" --filter status=running -q 2>/dev/null)
    if [ -n "$running" ]; then
        echo "PASS: $ctr container running"
    else
        echo "FAIL: $ctr container not running"
    fi
done

if curl -sf -o /dev/null http://localhost:4444/health/ready 2>/dev/null; then
    echo "PASS: Hydra public API healthy (port 4444)"
else
    echo "FAIL: Hydra public API not healthy"
fi

# ── Admin API ──
if curl -sf -o /dev/null http://localhost:4445/admin/clients 2>/dev/null; then
    echo "PASS: Hydra admin API reachable (port 4445)"
else
    echo "FAIL: Hydra admin API not reachable (port 4445)"
fi

# ── test-client exists ──
status=$(curl -sf -o /dev/null -w '%{http_code}' http://localhost:4445/admin/clients/test-client 2>/dev/null)
if [ "$status" = "200" ]; then
    echo "PASS: Hydra test-client OAuth client exists"
else
    echo "FAIL: Hydra test-client not found (HTTP $status)"
fi

if systemctl is-active --quiet filebeat 2>/dev/null; then
    echo "PASS: Filebeat service running"
else
    echo "FAIL: Filebeat service not running"
fi
BASH
)" "$TMPDIR_VAL/hydra1"
fi
}
