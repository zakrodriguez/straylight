#!/bin/bash
# scripts/checks/stepca1.sh — extracted from validate.sh verbatim.
register_checks_stepca1() {
# ─── STEPCA1 ─────────────────────────────────────────────────────────────

if is_running stepca1; then
    launch_check stepca1 run_linux_check stepca1 "$(cat <<'BASH'
running=$(docker ps --filter name=stepca --filter status=running -q 2>/dev/null)
if [ -n "$running" ]; then
    echo "PASS: step-ca container running"
else
    echo "FAIL: step-ca container not running"
fi

if docker exec stepca step ca health --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt >/dev/null 2>&1; then
    echo "PASS: step-ca health check OK"
else
    echo "FAIL: step-ca health check failed"
fi

# ── ACME provisioner ──
if docker exec stepca step ca provisioner list --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt 2>/dev/null | grep -qi 'acme'; then
    echo "PASS: ACME provisioner configured"
else
    echo "FAIL: ACME provisioner not found"
fi

if systemctl is-active --quiet filebeat 2>/dev/null; then
    echo "PASS: Filebeat service running"
else
    echo "FAIL: Filebeat service not running"
fi
BASH
)" "$TMPDIR_VAL/stepca1"
fi
}
