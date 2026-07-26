#!/bin/bash
# scripts/checks/scanner1.sh — CBOM scanner hub (CBOM-Lens, CipherIQ,
# source repos, cloudflare-pqc probe, CMS lab).
register_checks_scanner1() {
# ─── SCANNER1 ────────────────────────────────────────────────────────────

if is_running scanner1; then
    launch_check scanner1 run_linux_check scanner1 "$(cat <<'BASH'
# Docker engine
if systemctl is-active --quiet docker 2>/dev/null; then
    echo "PASS: docker service running"
else
    echo "FAIL: docker service not running"
fi

# CBOM-Lens scanner binary + output dir
if sudo test -x /opt/cbom-lens/cbom-lens && sudo test -d /opt/cbom-lens/output; then
    echo "PASS: CBOM-Lens installed (/opt/cbom-lens)"
else
    echo "FAIL: CBOM-Lens binary or output dir missing"
fi

# OpenSSL 3.5 side-install (PQC-capable probes)
if /opt/openssl-3.5/bin/openssl version 2>/dev/null | grep -q '^OpenSSL 3\.5'; then
    echo "PASS: OpenSSL 3.5 side-install present ($(/opt/openssl-3.5/bin/openssl version 2>/dev/null))"
else
    echo "FAIL: /opt/openssl-3.5/bin/openssl missing or wrong version"
fi

# CipherIQ — clone-only role (upstream ships no Dockerfiles): assert the
# tree and at least one SHA-pinned source clone.
if sudo test -d /opt/cipheriq && sudo test -d /opt/cipheriq/cbom-generator/.git; then
    echo "PASS: CipherIQ source clones present (/opt/cipheriq)"
else
    echo "FAIL: /opt/cipheriq source clones missing"
fi

# Source repos for static CBOM scans
if [ -d /opt/cbom-sources ] && [ -n "$(ls -A /opt/cbom-sources 2>/dev/null)" ]; then
    echo "PASS: CBOM source repos present ($(ls /opt/cbom-sources | wc -l) repo(s))"
else
    echo "FAIL: /opt/cbom-sources missing or empty"
fi

# cloudflare-pqc probe timer (6h cadence -> OSD panel)
if systemctl is-active --quiet cloudflare-pqc.timer 2>/dev/null; then
    echo "PASS: cloudflare-pqc.timer active"
else
    echo "FAIL: cloudflare-pqc.timer not active"
fi

# CMS hands-on lab tree — the role ends itself when issueca/issueca-pqc are
# not both in the inventory (e.g. profile `full`), and creates /opt/cms-lab
# first thing when it does run, so dir presence marks deployment exactly.
if [ -d /opt/cms-lab ]; then
    if [ -d /opt/cms-lab/inputs ]; then
        echo "PASS: CMS lab tree present (/opt/cms-lab)"
    else
        echo "FAIL: /opt/cms-lab exists but inputs/ missing"
    fi
else
    echo "PASS: CMS lab not deployed (no PQC issuing CA in this profile)"
fi

# Filebeat ships scanner output
if systemctl is-active --quiet filebeat 2>/dev/null; then
    echo "PASS: filebeat service running"
else
    echo "FAIL: filebeat service not running"
fi
BASH
)" "$TMPDIR_VAL/scanner1"
fi
}
