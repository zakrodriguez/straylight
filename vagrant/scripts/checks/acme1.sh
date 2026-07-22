#!/bin/bash
# scripts/checks/acme1.sh — extracted from validate.sh verbatim.
register_checks_acme1() {
# ─── ACME1 ───────────────────────────────────────────────────────────────

if is_running acme1; then
    local acme1_ip stepca_ip
    acme1_ip="${ACME1_IP:-$(lab_vm_ip acme1)}"; acme1_ip="${acme1_ip:-${LAB_NETWORK}.70}"
    stepca_ip="${STEPCA_IP:-$(lab_vm_ip stepca1)}"; stepca_ip="${stepca_ip:-${LAB_NETWORK}.51}"
    launch_check acme1 run_linux_check acme1 "DC1_IP=$DC1_IP
ACME1_IP=$acme1_ip
STEPCA_IP=$stepca_ip
$(cat <<'BASH'
# nginx
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "PASS: nginx service running"
else
    echo "FAIL: nginx service not running"
fi

# step CLI
if command -v step >/dev/null 2>&1 && step version >/dev/null 2>&1; then
    echo "PASS: step CLI installed ($(step version 2>&1 | head -1))"
else
    echo "FAIL: step CLI not installed"
fi

# acme.sh — /root/ is unreadable as vagrant user, so test via sudo only
if sudo test -x /root/.acme.sh/acme.sh && sudo /root/.acme.sh/acme.sh --version >/dev/null 2>&1; then
    echo "PASS: acme.sh installed ($(sudo /root/.acme.sh/acme.sh --version 2>&1 | tail -1))"
else
    echo "FAIL: acme.sh not installed"
fi

# step-ca root cert in system trust store
if [ -f /usr/local/share/ca-certificates/stepca-root.crt ]; then
    echo "PASS: step-ca root cert installed in system trust store"
else
    echo "FAIL: step-ca root cert not in /usr/local/share/ca-certificates/"
fi

# AD DNS A records (queried against DC1).
# Skipped on Linux-only profiles (no dc1) — name resolution there is done
# via /etc/hosts entries written by common_linux role.
if dig +short +time=2 +tries=1 @$DC1_IP . >/dev/null 2>&1; then
    for name in step.acme1.yourlab.local sh.acme1.yourlab.local; do
        resolved=$(dig +short "$name" @$DC1_IP 2>/dev/null | head -1)
        if [ "$resolved" = "$ACME1_IP" ]; then
            echo "PASS: AD DNS resolves $name -> $ACME1_IP"
        else
            echo "FAIL: AD DNS resolves $name -> '$resolved' (expected $ACME1_IP)"
        fi
    done
else
    echo "SKIP: AD DNS checks (dc1 not reachable — Linux-only profile)"
fi

# step-ca reachable from acme1 (chain validates against installed root)
if curl -sf --cacert /usr/local/share/ca-certificates/stepca-root.crt \
        https://$STEPCA_IP:9000/health 2>/dev/null | grep -q '"status":"ok"'; then
    echo "PASS: step-ca /health reachable from acme1 with installed root"
else
    echo "FAIL: step-ca /health not reachable / chain does not validate"
fi
BASH
)" "$TMPDIR_VAL/acme1"
fi
}
