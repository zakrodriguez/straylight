SSH=/opt/openssh-10/bin/ssh
if [ ! -x "$SSH" ]; then
    echo "FAIL: /opt/openssh-10/bin/ssh missing — run pqc-ssh.yml"
    exit 0
fi
if ! systemctl is-active --quiet sshd-pqc; then
    echo "FAIL: sshd-pqc unit not active"
    exit 0
fi
echo "PASS: sshd-pqc systemd unit active"
if ! ss -ltn | awk '{print $4}' | grep -q ':2222$'; then
    echo "FAIL: nothing listening on :2222"
    exit 0
fi
debug=$(timeout 8 $SSH -v -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o KexAlgorithms=mlkem768x25519-sha256 \
    -o ConnectTimeout=5 \
    nobody@127.0.0.1 echo ok 2>&1 || true)
if echo "$debug" | grep -q 'kex: algorithm: mlkem768x25519-sha256'; then
    echo "PASS: KEX negotiated as mlkem768x25519-sha256 (NIST standardized PQC hybrid)"
else
    echo "FAIL: mlkem768x25519-sha256 not negotiated"
fi
