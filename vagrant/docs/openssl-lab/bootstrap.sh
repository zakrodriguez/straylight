#!/usr/bin/env bash
# bootstrap.sh — Generate all sample certs/keys for the openssl-lab lessons.
#
# Usage:
#   bash bootstrap.sh                 # generate everything (skip lessons already done)
#   bash bootstrap.sh --only 06       # generate only lesson 06's certs
#   bash bootstrap.sh --force         # wipe certs/ and regenerate everything
#
# Output: vagrant/docs/openssl-lab/certs/<NN>-<topic>/  (one dir per lesson)
# Each lesson directory ends with a .ready marker file when generation succeeds.
set -euo pipefail

# ── Locate ourselves ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS="$SCRIPT_DIR/certs"

# ── Parse args ──────────────────────────────────────────────────────────
ONLY=""
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      sed -n 's/^# //p' "$0" | head -10
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Validate openssl 3.x ────────────────────────────────────────────────
if ! openssl version | grep -qE '^OpenSSL 3\.'; then
  echo "ERROR: OpenSSL 3.x required. Got: $(openssl version)" >&2
  echo "  This lab uses 3.x-only flags (genpkey, req -addext, etc.)." >&2
  exit 1
fi

# ── Optional: wipe everything ───────────────────────────────────────────
if $FORCE; then
  echo "→ --force: wiping $CERTS"
  rm -rf "$CERTS"
fi
mkdir -p "$CERTS"

# ── Per-lesson generator functions ──────────────────────────────────────
# Each function:
#   - cd into its own subdir under $CERTS
#   - generates required artifacts using openssl
#   - touches .ready as the last step (idempotency marker)
# One gen_NN_<topic> function per lesson follows, then the dispatcher.

gen_01_inspect() {
  cat > req.conf <<'CONF'
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = leaf.example.com
O = Example Org
[ext]
subjectAltName = DNS:leaf.example.com,DNS:www.example.com,IP:10.0.0.42
CONF
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout leaf.key -out leaf.crt \
    -days 365 -config req.conf -extensions ext >/dev/null 2>&1
  rm -f req.conf
}

gen_02_chain() {
  # Root CA (self-signed)
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout root.key -out root.crt -days 365 \
    -subj "/CN=Lab Root CA/O=Example Org" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

  # Intermediate (signed by root)
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out intermediate.key 2>/dev/null
  openssl req -new -key intermediate.key -out intermediate.csr \
    -subj "/CN=Lab Intermediate CA/O=Example Org" 2>/dev/null
  openssl x509 -req -in intermediate.csr -CA root.crt -CAkey root.key \
    -CAcreateserial -out intermediate.crt -days 365 \
    -extfile <(printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n") 2>/dev/null

  # Leaf (signed by intermediate)
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out leaf.key 2>/dev/null
  openssl req -new -key leaf.key -out leaf.csr \
    -subj "/CN=leaf.example.com/O=Example Org" 2>/dev/null
  openssl x509 -req -in leaf.csr -CA intermediate.crt -CAkey intermediate.key \
    -CAcreateserial -out leaf.crt -days 90 \
    -extfile <(printf "subjectAltName=DNS:leaf.example.com\n") 2>/dev/null

  # Bundle = leaf + intermediate (no root) — standard "chain" format
  cat leaf.crt intermediate.crt > chain.pem
  rm -f *.csr *.srl
}

gen_03_csr() {
  # Operator-facing CSR config — they'll use this in the lesson.
  cat > req.conf <<'CONF'
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = api.example.com
O = Example Org
C = US
[ext]
subjectAltName = DNS:api.example.com,DNS:api-staging.example.com
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
CONF
  # That's all for setup — the lesson has the operator generate the key + CSR.
}

gen_04_selfsign() {
  # Pre-baked CSR for the operator to self-sign in the lesson.
  cat > req.conf <<'CONF'
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = devbox.local
[ext]
subjectAltName = DNS:devbox.local,DNS:localhost,IP:127.0.0.1
CONF
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out devbox.key 2>/dev/null
  openssl req -new -key devbox.key -out devbox.csr -config req.conf 2>/dev/null
}

gen_05_formats() {
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout cert.key -out cert.crt -days 365 \
    -subj "/CN=format-demo.example.com" >/dev/null 2>&1
}

gen_06_handshake() {
  # Server cert + key for s_server to present.
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server.key -out server.crt -days 90 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1

  # Convenience launcher script — operator runs this in a separate terminal.
  cat > start-server.sh <<'SH'
#!/usr/bin/env bash
# Start s_server on localhost:8443 with the lesson's cert.
cd "$(dirname "$0")"
exec openssl s_server -cert server.crt -key server.key -accept 8443 -www
SH
  chmod +x start-server.sh
}

gen_07_crl() {
  # Minimal CA setup so we can issue + revoke a cert + sign a CRL.
  mkdir -p ca/{newcerts,private,crl}
  touch ca/index.txt
  echo 1000 > ca/serial
  echo 1000 > ca/crlnumber

  cat > openssl.cnf <<'CONF'
[ca]
default_ca = lab_ca

[lab_ca]
dir              = ./ca
database         = $dir/index.txt
new_certs_dir    = $dir/newcerts
serial           = $dir/serial
crlnumber        = $dir/crlnumber
crl              = $dir/crl/lab.crl
default_md       = sha256
default_days     = 365
default_crl_days = 30
policy           = any_policy
copy_extensions  = copy
unique_subject   = no

[any_policy]
commonName = supplied

[req]
distinguished_name = dn
prompt = no
[dn]
CN = Lab CA
CONF

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout ca/private/ca.key -out ca/cacert.crt -days 365 \
    -subj "/CN=Lab CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

  # Issue a leaf cert signed by the lab CA
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out leaf.key 2>/dev/null
  openssl req -new -key leaf.key -out leaf.csr -subj "/CN=will-be-revoked.example.com" 2>/dev/null
  openssl ca -batch -config openssl.cnf -in leaf.csr -out leaf.crt \
    -keyfile ca/private/ca.key -cert ca/cacert.crt >/dev/null 2>&1

  # Revoke + generate a CRL
  openssl ca -batch -config openssl.cnf -revoke leaf.crt \
    -keyfile ca/private/ca.key -cert ca/cacert.crt >/dev/null 2>&1
  openssl ca -batch -config openssl.cnf -gencrl -out ca/crl/lab.crl \
    -keyfile ca/private/ca.key -cert ca/cacert.crt >/dev/null 2>&1

  # Tidy up the operator-facing layout
  cp ca/cacert.crt ./ca.crt
  cp ca/crl/lab.crl ./lab.crl
  rm -rf ca leaf.csr openssl.cnf
}

gen_08_ocsp() {
  # Reuse the lesson 07 CA + leaf if present (fast). Otherwise re-create.
  if [[ -f "$CERTS/07-crl/ca.crt" ]]; then
    cp "$CERTS/07-crl/ca.crt" issuer.crt
    cp "$CERTS/07-crl/leaf.crt" leaf.crt
  else
    # Standalone fallback: build a tiny CA + leaf inline
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout issuer.key -out issuer.crt -days 365 \
      -subj "/CN=Lab CA" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out leaf.key 2>/dev/null
    openssl req -new -key leaf.key -out leaf.csr -subj "/CN=ocsp-test.example.com" 2>/dev/null
    openssl x509 -req -in leaf.csr -CA issuer.crt -CAkey issuer.key \
      -CAcreateserial -out leaf.crt -days 90 2>/dev/null
    rm -f leaf.csr issuer.srl
  fi

  # Build the index file the responder reads (status flags: V=valid, R=revoked).
  serial=$(openssl x509 -in leaf.crt -serial -noout | cut -d= -f2)
  printf "V\t%sZ\t\t%s\tunknown\t/CN=ocsp-test.example.com\n" \
    "$(date -u -d '+90 days' +%y%m%d%H%M%S 2>/dev/null || date -u -v+90d +%y%m%d%H%M%S)" \
    "$serial" > index.txt

  # Need the issuer's private key to sign OCSP responses. If we copied
  # from lesson 07 we don't have it; re-derive by re-issuing.
  if [[ ! -f issuer.key ]]; then
    cp "$CERTS/07-crl/leaf.key" /dev/null 2>/dev/null || true
    # Lesson 07 does not expose the CA key publicly. For lesson 08 we
    # generate our own issuer + leaf so the responder works.
    rm -f issuer.crt leaf.crt leaf.key index.txt
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout issuer.key -out issuer.crt -days 365 \
      -subj "/CN=Lab OCSP CA" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out leaf.key 2>/dev/null
    openssl req -new -key leaf.key -out leaf.csr -subj "/CN=ocsp-test.example.com" 2>/dev/null
    openssl x509 -req -in leaf.csr -CA issuer.crt -CAkey issuer.key \
      -CAcreateserial -out leaf.crt -days 90 2>/dev/null
    rm -f leaf.csr issuer.srl
    serial=$(openssl x509 -in leaf.crt -serial -noout | cut -d= -f2)
    printf "V\t%sZ\t\t%s\tunknown\t/CN=ocsp-test.example.com\n" \
      "$(date -u -d '+90 days' +%y%m%d%H%M%S 2>/dev/null || date -u -v+90d +%y%m%d%H%M%S)" \
      "$serial" > index.txt
  fi

  # Convenience launcher script — operator runs this in a separate terminal.
  cat > start-responder.sh <<'SH'
#!/usr/bin/env bash
# Start an OCSP responder on localhost:8888 backed by index.txt
cd "$(dirname "$0")"
exec openssl ocsp -port 8888 -index index.txt -CA issuer.crt -rsigner issuer.crt -rkey issuer.key
SH
  chmod +x start-responder.sh
}

gen_09_extensions() {
  # A "kitchen sink" cert with several extensions worth decoding.
  cat > req.conf <<'CONF'
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = api.example.com
[ext]
subjectAltName = DNS:api.example.com,DNS:api-staging.example.com,DNS:*.api.example.com,IP:10.0.0.42,email:ops@example.com
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth,codeSigning
basicConstraints = CA:FALSE
authorityInfoAccess = OCSP;URI:http://ocsp.example.com,caIssuers;URI:http://ca.example.com/ca.crt
crlDistributionPoints = URI:http://crl.example.com/lab.crl
CONF
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout cert.key -out cert.crt -days 365 \
    -config req.conf -extensions ext >/dev/null 2>&1
  rm -f req.conf
}

gen_10_hostname() {
  # Cert intentionally has only ONE SAN — when you connect with a
  # different hostname, verify_hostname will fail.
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server.key -out server.crt -days 90 \
    -subj "/CN=correct-name.example.com" \
    -addext "subjectAltName=DNS:correct-name.example.com" >/dev/null 2>&1

  cat > start-server.sh <<'SH'
#!/usr/bin/env bash
cd "$(dirname "$0")"
exec openssl s_server -cert server.crt -key server.key -accept 8444 -www
SH
  chmod +x start-server.sh
}

gen_11_ciphers() {
  # No artifacts needed for the cipher-string lessons; they use
  # `openssl ciphers` and built-in lookups. Touching .ready below.
  echo "(No certs needed — lesson uses 'openssl ciphers' to inspect the system's cipher table.)" > NOTES.txt
}

gen_12_sign() {
  # Generate a keypair + extract the public key. The operator will sign
  # a small payload and verify it.
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out priv.key 2>/dev/null
  openssl pkey -in priv.key -pubout -out pub.key 2>/dev/null
  echo "important-message-2026" > payload.txt
}

gen_13_bundle() {
  # Reuse the chain from lesson 02 if present.
  if [[ -f "$CERTS/02-chain/chain.pem" ]]; then
    cp "$CERTS/02-chain/chain.pem" chain.pem
    cp "$CERTS/02-chain/root.crt" root.crt
  else
    # Standalone fallback: build a tiny chain inline.
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout root.key -out root.crt -days 365 \
      -subj "/CN=Lab Root CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out int.key 2>/dev/null
    openssl req -new -key int.key -out int.csr -subj "/CN=Lab Intermediate CA" 2>/dev/null
    openssl x509 -req -in int.csr -CA root.crt -CAkey root.key \
      -CAcreateserial -out int.crt -days 365 \
      -extfile <(printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n") 2>/dev/null
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out leaf.key 2>/dev/null
    openssl req -new -key leaf.key -out leaf.csr -subj "/CN=leaf.example.com" 2>/dev/null
    openssl x509 -req -in leaf.csr -CA int.crt -CAkey int.key \
      -CAcreateserial -out leaf.crt -days 90 2>/dev/null
    cat leaf.crt int.crt > chain.pem
    rm -f int.* leaf.csr root.key root.srl int.srl
  fi
}

# ── Dispatcher ──────────────────────────────────────────────────────────
# Discover all gen_NN_* functions defined above and call them in order.
all_lessons() {
  declare -F | awk '/^declare -f gen_[0-9]+_/ {print $3}' | sort
}

run_one() {
  local fn="$1"
  local nn="${fn#gen_}"
  nn="${nn%%_*}"
  local topic="${fn#gen_${nn}_}"
  local dir="$CERTS/${nn}-${topic//_/-}"
  if [[ -f "$dir/.ready" ]]; then
    echo "✓ ${nn} already done (skip — delete $dir/.ready or pass --force to regenerate)"
    return 0
  fi
  echo "→ Generating ${nn} (${topic})..."
  mkdir -p "$dir"
  ( cd "$dir" && "$fn" )
  touch "$dir/.ready"
  echo "✓ ${nn} done"
}

if [[ -n "$ONLY" ]]; then
  fn=$(all_lessons | grep "^gen_${ONLY}_" | head -1)
  if [[ -z "$fn" ]]; then
    echo "ERROR: no generator function matches lesson '${ONLY}'" >&2
    echo "Available: $(all_lessons | tr '\n' ' ')" >&2
    exit 1
  fi
  run_one "$fn"
else
  for fn in $(all_lessons); do
    run_one "$fn"
  done
fi

# ── Stamp completion ────────────────────────────────────────────────────
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$CERTS/.bootstrap-time"
echo
echo "All done. Re-bootstrap if certs/.bootstrap-time is older than 60 days."
