#!/bin/bash
# scripts/checks/vpn1.sh — strongSwan S2S initiator (az700-hybrid).
# Tunnel-tolerant by design: the Azure gateway is ephemeral (same-day
# teardown), so an un-established SA is a reportable state, not a failure.
register_checks_vpn1() {
# ─── VPN1 ────────────────────────────────────────────────────────────────

if is_running vpn1; then
    launch_check vpn1 run_linux_check vpn1 "$(cat <<'BASH'
# charon (strongswan.service via charon-systemd)
if systemctl is-active --quiet strongswan 2>/dev/null; then
    echo "PASS: strongswan (charon) service running"
else
    echo "FAIL: strongswan service not running"
fi

# Forwarding — vpn1 routes for the whole lab
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then
    echo "PASS: net.ipv4.ip_forward enabled"
else
    echo "FAIL: net.ipv4.ip_forward disabled"
fi

# Connection config: present => must be loaded; absent => legitimate
# pre-Azure state (deploy hybrid-vpn, then re-provision vpn1).
if sudo test -f /etc/swanctl/conf.d/azure.conf; then
    if sudo swanctl --list-conns 2>/dev/null | grep -q '^azure:'; then
        echo "PASS: azure connection loaded in swanctl"
    else
        echo "FAIL: azure.conf present but connection not loaded"
    fi
    if sudo swanctl --list-sas 2>/dev/null | grep -q 'ESTABLISHED'; then
        echo "PASS: S2S tunnel ESTABLISHED"
    else
        echo "PASS: tunnel configured, not established (Azure gateway down or unreachable — expected between hybrid sessions)"
    fi
else
    echo "PASS: tunnel not configured yet (no hybrid-vpn deployment recorded — run az700.sh deploy hybrid-vpn, then re-provision vpn1)"
fi
BASH
)" "$TMPDIR_VAL/vpn1"
fi
}
