#!/bin/bash
# scripts/checks/observe1.sh — extracted from validate.sh verbatim.
register_checks_observe1() {
# ─── OBSERVE1 ──────────────────────────────────────────────────────────

if is_running observe1; then
    launch_check observe1 run_linux_check observe1 "$(cat <<'BASH'
for ctr in opensearch opensearch-dashboards; do
    running=$(docker ps --filter name="^${ctr}$" --filter status=running -q 2>/dev/null)
    if [ -n "$running" ]; then
        echo "PASS: $ctr container running"
    else
        echo "FAIL: $ctr container not running"
    fi
done

# ── OpenSearch API (loopback only — :9200 no longer bound on LAN) ──
if curl -sf -o /dev/null http://localhost:9200 2>/dev/null; then
    echo "PASS: OpenSearch API reachable on loopback (127.0.0.1:9200)"
else
    echo "FAIL: OpenSearch API not reachable on loopback"
fi

# ── :9200 must NOT be reachable on the LAN interface (TLS-only via :9244) ──
lan_ip=$(hostname -I 2>/dev/null | awk '{print $2}')
if [ -n "$lan_ip" ] && curl -sf --max-time 3 -o /dev/null "http://${lan_ip}:9200" 2>/dev/null; then
    echo "FAIL: OpenSearch :9200 still reachable on LAN (${lan_ip}) — should be loopback-only"
else
    echo "PASS: OpenSearch :9200 not reachable on LAN (loopback-only as expected)"
fi

# ── Beats TLS data port (:9244) — should require auth + serve a cert ──
unauth=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://localhost:9244/_cluster/health" 2>/dev/null || echo 000)
if [ "$unauth" = "401" ]; then
    echo "PASS: Beats TLS port :9244 challenges unauthenticated requests (401)"
else
    echo "FAIL: Beats TLS port :9244 returned '$unauth' for unauthenticated probe (expected 401)"
fi

# ── OpenSearch Dashboards ──
if curl -sf -o /dev/null http://localhost:5601 2>/dev/null; then
    echo "PASS: OpenSearch Dashboards reachable (port 5601)"
else
    echo "FAIL: OpenSearch Dashboards not reachable"
fi

# ── Beats agents ship to https://{observe_ip}:9244 (TLS + Basic Auth via nginx) ──

# ── OpenSearch sysctl ──
val=$(sysctl vm.max_map_count 2>/dev/null | awk '{print $3}')
if [ "$val" = "262144" ]; then
    echo "PASS: vm.max_map_count = 262144"
else
    echo "FAIL: vm.max_map_count = $val (expected 262144)"
fi

if systemctl is-active --quiet filebeat 2>/dev/null; then
    echo "PASS: Filebeat service running"
else
    echo "FAIL: Filebeat service not running"
fi
BASH
)" "$TMPDIR_VAL/observe1"
fi

# ─── OBSERVE1 ACME TLS retrofit (phase 2) ──────────────────────────────
# Only meaningful when the profile includes stepca1 (the issuing CA for
# observe1's :443 cert). Profiles without stepca1 (e.g. ad-cs-*)
# legitimately have no nginx + no acme-renew.timer + no step CLI.
if is_running observe1 && profile_has stepca1; then
    launch_check "observe1-acme" run_linux_check observe1 "DC1_IP=$(lab_vm_ip dc1)
OBSERVE1_IP=$(lab_vm_ip observe1)
$(cat <<'BASH'
# host nginx (NOT the docker beats-proxy)
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "PASS: host nginx service running"
else
    echo "FAIL: host nginx service not running"
fi

# step CLI installed
if command -v step >/dev/null 2>&1 && step version >/dev/null 2>&1; then
    echo "PASS: step CLI installed on observe1 ($(step version 2>&1 | head -1))"
else
    echo "FAIL: step CLI not installed on observe1"
fi

# step-ca root cert in system trust store
if [ -f /usr/local/share/ca-certificates/stepca-root.crt ]; then
    echo "PASS: step-ca root cert in observe1 trust store"
else
    echo "FAIL: step-ca root cert missing on observe1"
fi

# AD DNS A record for observe1.yourlab.local.
# Skipped on Linux-only profiles (no dc1) — observe1 resolves via /etc/hosts.
if dig +short +time=2 +tries=1 @$DC1_IP . >/dev/null 2>&1; then
    resolved=$(dig +short observe1.yourlab.local @$DC1_IP 2>/dev/null | head -1)
    if [ "$resolved" = "$OBSERVE1_IP" ]; then
        echo "PASS: AD DNS resolves observe1.yourlab.local -> $OBSERVE1_IP"
    else
        echo "FAIL: AD DNS resolves observe1.yourlab.local -> '$resolved' (expected $OBSERVE1_IP)"
    fi
else
    echo "SKIP: AD DNS check for observe1 (dc1 not reachable — Linux-only profile)"
fi

# HTTPS reaches OSD through proxy (end-to-end)
if curl -sf --resolve observe1.yourlab.local:443:127.0.0.1 \
        https://observe1.yourlab.local/api/status \
        -o /dev/null 2>/dev/null; then
    echo "PASS: https://observe1.yourlab.local/api/status returns 200 via TLS proxy"
else
    echo "FAIL: https://observe1.yourlab.local/api/status not reachable / chain invalid"
fi

# Cert issuer is step-ca (not chimera, not self-signed)
issuer=$(echo | openssl s_client -connect 127.0.0.1:443 -servername observe1.yourlab.local 2>/dev/null \
         | openssl x509 -noout -issuer 2>/dev/null)
if echo "$issuer" | grep -q "Smallstep-CA Intermediate CA"; then
    echo "PASS: observe1:443 cert issuer is Smallstep-CA Intermediate CA"
else
    echo "FAIL: observe1:443 cert issuer is '$issuer' (expected Smallstep-CA Intermediate CA)"
fi

# Renewal timer armed and active
if systemctl is-active --quiet acme-renew.timer 2>/dev/null; then
    echo "PASS: acme-renew.timer active (renewal automation armed)"
else
    echo "FAIL: acme-renew.timer not active"
fi
BASH
)" "$TMPDIR_VAL/observe1-acme"
fi
}
