#!/bin/bash
# cloudflare_pqc probe orchestrator
# Runs 3 endpoints × 3 stacks and assembles a single JSON report.
#
# Stacks:
#   1. go-stdlib-mlkem   — /opt/cloudflare-pqc/cf-pqc-probe
#   2. openssl-oqs       — /opt/openssl-3.5/bin/openssl s_client -groups X25519MLKEM768
#   3. curl-system       — /usr/bin/curl --tlsv1.3 (no PQC, control)
#
# Output: writes /var/lib/cloudflare-pqc/report.json (atomic via mv)
set -euo pipefail

ROLE_DIR=/opt/cloudflare-pqc
REPORT_DIR=/var/lib/cloudflare-pqc
REPORT_PATH="$REPORT_DIR/report.json"
TMP_REPORT="$(mktemp "$REPORT_DIR/report.XXXXXX.json")"

# OQS-OpenSSL location from openssl_35 role.
OQS_OPENSSL=/opt/openssl-3.5/bin/openssl

declare -A ENDPOINTS=(
    [cloudflare-com]=cloudflare.com:443
    [pq-research]=pq.cloudflareresearch.com:443
    [one-one-doh]=1.1.1.1:443
)

run_go_probe() {
    local host_port=$1
    "$ROLE_DIR/cf-pqc-probe" --endpoint "$host_port" 2>/dev/null || \
        printf '{"endpoint":"%s","stack":"go-stdlib-mlkem","success":false,"error":"probe binary failed to execute"}\n' "$host_port"
}

run_openssl_oqs() {
    local host_port=$1
    local host=${host_port%:*}
    local port=${host_port##*:}
    local stack=openssl-oqs

    if [[ ! -x "$OQS_OPENSSL" ]]; then
        printf '{"endpoint":"%s","stack":"%s","success":false,"error":"openssl 3.5 not installed"}\n' "$host_port" "$stack"
        return
    fi

    local start_ms=$(date +%s%N)
    local out
    out=$(timeout 15 "$OQS_OPENSSL" s_client \
        -connect "$host_port" \
        -servername "$host" \
        -groups X25519MLKEM768 \
        -tls1_3 \
        -brief </dev/null 2>&1) || {
            local err=$(echo "$out" | tr '\n' ' ' | sed 's/"/\\"/g' | head -c 200)
            printf '{"endpoint":"%s","stack":"%s","success":false,"error":"%s"}\n' "$host_port" "$stack" "$err"
            return
        }
    local end_ms=$(date +%s%N)
    local elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))

    local cipher tls_version
    cipher=$(echo "$out" | awk -F': *' '/^Ciphersuite/ {print $2; exit}')
    tls_version=$(echo "$out" | awk -F': *' '/^Protocol *version/ {print $2; exit}')

    printf '{"endpoint":"%s","stack":"%s","success":true,"tls_version":"%s","cipher":"%s","kex_group_offered":"X25519MLKEM768","handshake_ms":%d}\n' \
        "$host_port" "$stack" "${tls_version:-unknown}" "${cipher:-unknown}" "$elapsed_ms"
}

run_curl_control() {
    local host_port=$1
    local host=${host_port%:*}
    local stack=curl-system

    local start_ms=$(date +%s%N)
    # --tls13-ciphers is set so output mentions cipher.
    # We don't expect PQC here; this is the classical-only baseline.
    local out
    if [[ "$host_port" == *"/dns-query"* ]] || [[ "$host_port" == "1.1.1.1:443" ]]; then
        # 1.1.1.1 returns a real HTTPS page on https://1.1.1.1/ so curl can probe it.
        out=$(curl -v --max-time 10 --tlsv1.3 -o /dev/null -sS "https://$host/" 2>&1) || true
    else
        out=$(curl -v --max-time 10 --tlsv1.3 -o /dev/null -sS "https://$host/" 2>&1) || true
    fi
    local end_ms=$(date +%s%N)
    local elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))

    if echo "$out" | grep -q "SSL connection using TLSv1.3"; then
        local cipher
        cipher=$(echo "$out" | sed -n 's/.*SSL connection using TLSv1.3 \/ \(.*\) \/.*/\1/p' | head -1)
        printf '{"endpoint":"%s","stack":"%s","success":true,"tls_version":"TLSv1.3","cipher":"%s","kex_group_offered":"classical-default","handshake_ms":%d}\n' \
            "$host_port" "$stack" "${cipher:-unknown}" "$elapsed_ms"
    else
        local err=$(echo "$out" | tail -1 | tr -d '"' | head -c 200)
        printf '{"endpoint":"%s","stack":"%s","success":false,"error":"%s"}\n' "$host_port" "$stack" "$err"
    fi
}

# Assemble the report.
{
    echo '{'
    echo '  "schema": "cloudflare_pqc/v1",'
    echo "  \"run_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"scanner\": \"$(hostname -s)\","
    echo '  "probes": ['
    first=true
    for endpoint_name in "${!ENDPOINTS[@]}"; do
        host_port=${ENDPOINTS[$endpoint_name]}
        for stack_fn in run_go_probe run_openssl_oqs run_curl_control; do
            if $first; then first=false; else echo "    ,"; fi
            line=$("$stack_fn" "$host_port")
            # Add endpoint_name field for grouping.
            echo "    $(echo "$line" | sed "s/^{/{\"endpoint_name\":\"$endpoint_name\",/")"
        done
    done
    echo '  ]'
    echo '}'
} > "$TMP_REPORT"

# Atomic publish.
mv "$TMP_REPORT" "$REPORT_PATH"
chmod 0644 "$REPORT_PATH"

echo "Wrote $REPORT_PATH"
