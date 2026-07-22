OSSL=/opt/openssl-3.5/bin/openssl
if [ ! -x "$OSSL" ]; then
    echo "FAIL: /opt/openssl-3.5/bin/openssl missing — run pqc-pure-leaf.yml"
    exit 0
fi
if ! systemctl is-active --quiet openssl-pqc-pure; then
    echo "FAIL: openssl-pqc-pure systemd unit not active"
    exit 0
fi
echo "PASS: openssl-pqc-pure systemd unit active"
if ! ss -ltn | awk '{print $4}' | grep -q ":${PORT}$"; then
    echo "FAIL: nothing listening on :${PORT}"
    exit 0
fi
echo "PASS: TCP listener on :${PORT}"
result=$(echo | timeout 5 $OSSL s_client \
    -connect 127.0.0.1:${PORT} \
    -CAfile /opt/pqc-certs/ejbca-pqc-chain.pem \
    -verify_return_error 2>&1)
if echo "$result" | grep -q 'Verify return code: 0 (ok)'; then
    echo "PASS: ML-DSA-65 TLS handshake completes with full chain validation"
else
    echo "FAIL: ML-DSA-65 handshake/chain validation — $(echo "$result" | grep 'Verify return code:' | head -1)"
fi
leaf=$(echo | $OSSL s_client -connect 127.0.0.1:${PORT} 2>/dev/null | $OSSL x509 -noout -text 2>/dev/null)
if echo "$leaf" | grep -q 'Public Key Algorithm: ML-DSA-65'; then
    echo "PASS: served leaf has Public Key Algorithm ML-DSA-65"
else
    echo "FAIL: served leaf is not ML-DSA-65 — $(echo "$leaf" | grep -m1 'Public Key Algorithm')"
fi
if echo "$leaf" | grep -q 'Signature Algorithm: ML-DSA-65'; then
    echo "PASS: served leaf signature algorithm is ML-DSA-65"
else
    echo "FAIL: served leaf signature algo not ML-DSA-65"
fi
sys_result=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:${PORT} 2>&1 || true)
if echo "$sys_result" | grep -qE 'unknown algorithm|unsupported|alert|handshake fail|no peer certificate'; then
    echo "PASS: legacy system openssl rejects pure-PQC endpoint (expected)"
else
    echo "FAIL: system openssl unexpectedly handshook with pure-PQC endpoint"
fi
