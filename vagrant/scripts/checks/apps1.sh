#!/bin/bash
# scripts/checks/apps1.sh — CBOM scan-target application stack (Docker apps).
register_checks_apps1() {
# ─── APPS1 ───────────────────────────────────────────────────────────────

if is_running apps1; then
    launch_check apps1 run_linux_check apps1 "$(cat <<'BASH'
# Docker engine
if systemctl is-active --quiet docker 2>/dev/null; then
    echo "PASS: docker service running"
else
    echo "FAIL: docker service not running"
fi

# Application containers (compose projects under /opt/<app>)
running="$(sudo docker ps --format '{{.Names}}' 2>/dev/null)"
for c in keycloak keycloak-db vault nifi gitea minio; do
    if grep -qx "$c" <<< "$running"; then
        echo "PASS: container '$c' running"
    else
        echo "FAIL: container '$c' not running"
    fi
done

# Published app ports
for p in 8080 8200 8444 3000 9010; do
    if ss -tln 2>/dev/null | grep -q ":$p "; then
        echo "PASS: port $p listening"
    else
        echo "FAIL: port $p not listening"
    fi
done

# Filebeat ships the container/app logs
if systemctl is-active --quiet filebeat 2>/dev/null; then
    echo "PASS: filebeat service running"
else
    echo "FAIL: filebeat service not running"
fi
BASH
)" "$TMPDIR_VAL/apps1"
fi
}
