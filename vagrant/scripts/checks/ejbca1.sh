#!/bin/bash
# scripts/checks/ejbca1.sh — extracted from validate.sh verbatim.
register_checks_ejbca1() {
# ─── EJBCA1 ──────────────────────────────────────────────────────────────

if is_running ejbca1; then
    launch_check ejbca1 run_linux_check ejbca1 "TOPOLOGY=${TOPOLOGY}
$(cat <<'BASH'
# ── Containers ──
for ctr in ejbca-ce ejbca-db; do
    running=$(docker ps --filter name="^${ctr}$" --filter status=running -q 2>/dev/null)
    if [ -n "$running" ]; then
        echo "PASS: $ctr container running"
    else
        echo "FAIL: $ctr container not running"
    fi
done

# ── CA service ──
if docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca listcas >/dev/null 2>&1; then
    echo "PASS: EJBCA CA service responding"
else
    echo "FAIL: EJBCA CA service not responding"
fi

# ── CAs exist ──
ca_list=$(docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca listcas 2>/dev/null)
if echo "$ca_list" | grep -qi 'root'; then
    echo "PASS: EJBCA Root CA exists"
else
    echo "FAIL: EJBCA Root CA not found"
fi
if profile_has issueca; then
    if echo "$ca_list" | grep -qi 'issuing\|subordinate'; then
        echo "PASS: EJBCA Issuing CA exists"
    else
        echo "FAIL: EJBCA Issuing CA not found"
    fi
fi

# ── Public web endpoint (8080 responds, 403 is normal for CE) ──
http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/ejbca/publicweb/ 2>/dev/null)
if [ "$http_code" = "200" ] || [ "$http_code" = "403" ]; then
    echo "PASS: EJBCA public web (port 8080) reachable (HTTP $http_code)"
else
    echo "FAIL: EJBCA public web (port 8080) not reachable (HTTP $http_code)"
fi

# ── Filebeat ──
if systemctl is-active --quiet filebeat 2>/dev/null; then
    echo "PASS: Filebeat service running"
else
    echo "FAIL: Filebeat service not running"
fi
BASH
)" "$TMPDIR_VAL/ejbca1"
fi

# ─── PQC VALIDATION ──────────────────────────────────────────────────────
# Gated on PQC CAs actually being present — they're created by pqc-migrate.yml,
# not by the standard ejbca role. Profiles that include ejbca1 but don't run
# pqc-migrate (ejbca-only, full pre-migrate) get SKIP lines, not FAIL.
if is_running ejbca1; then
    launch_check "ejbca1-pqc" run_linux_check ejbca1 "$(cat <<'BASH'
# Quick probe: did pqc-migrate.yml run? (creates EJBCA-PQC-Root-CA)
PQC_AVAILABLE=true
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca info --caname "EJBCA-PQC-Root-CA" >/dev/null 2>&1 || PQC_AVAILABLE=false

# Check PQC CAs exist
for ca in "EJBCA-PQC-Root-CA" "EJBCA-PQC-Issuing-CA" "EJBCA-Chimera-Root-CA"; do
    if [ "$PQC_AVAILABLE" = "false" ]; then
        echo "SKIP: $ca check (pqc-migrate.yml not run for this profile)"
    elif docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca info --caname "$ca" >/dev/null 2>&1; then
        echo "PASS: $ca exists"
    else
        echo "FAIL: $ca not found"
    fi
done

# Check PQC cert exports
for cert in ejbca-pqc-root-ca.pem ejbca-pqc-issuing-ca.pem ejbca-chimera-root-ca.pem; do
    if [ "$PQC_AVAILABLE" = "false" ]; then
        echo "SKIP: $cert check (pqc-migrate.yml not run for this profile)"
    elif [ -f "/opt/ejbca/data/export/$cert" ]; then
        echo "PASS: $cert exported"
    else
        echo "FAIL: $cert not found in /opt/ejbca/data/export/"
    fi
done
BASH
)" "$TMPDIR_VAL/ejbca1-pqc"
fi
}
