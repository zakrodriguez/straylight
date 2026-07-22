# Lesson 11: Cipher suites + protocol versions

**Skill level:** advanced
**Time:** ~20 min
**Prereqs:** Lesson 06

## Goal

Read OpenSSL's cipher-string mini-language, list the ciphers a configuration enables, and force `s_client` to negotiate a specific cipher or protocol version.

## Setup

No certs needed — this lesson uses openssl's built-in cipher table.

If you skipped bootstrap: `bash bootstrap.sh --only 11`

## Walkthrough

### Step 1: Show ALL ciphers openssl knows about

```bash
$ openssl ciphers -v 'ALL' | head -10
```

**Why:** `ciphers` evaluates a cipher string and prints which suites it expands to. `'ALL'` is everything available. `-v` adds verbose columns: name, protocol, key exchange, auth, encryption, MAC.

**Expected output (truncated):**
```
TLS_AES_256_GCM_SHA384         TLSv1.3 Kx=any      Au=any  Enc=AESGCM(256)            Mac=AEAD
TLS_CHACHA20_POLY1305_SHA256   TLSv1.3 Kx=any      Au=any  Enc=CHACHA20/POLY1305(256) Mac=AEAD
ECDHE-RSA-AES256-GCM-SHA384    TLSv1.2 Kx=ECDH     Au=RSA  Enc=AESGCM(256)            Mac=AEAD
...
```

The TLS 1.3 suites are listed by their IANA name (`TLS_*`); the TLS 1.2 suites use OpenSSL's older naming.

### Step 2: Filter by criteria using the cipher-string DSL

```bash
$ openssl ciphers -v 'ECDHE+AESGCM' | head -5
```

**Why:** the cipher-string DSL combines tokens with `+` (must contain — intersection) and `:` (separator).

**Expected output:**
```
TLS_AES_256_GCM_SHA384         TLSv1.3 ...
TLS_CHACHA20_POLY1305_SHA256   TLSv1.3 ...
TLS_AES_128_GCM_SHA256         TLSv1.3 ...
ECDHE-ECDSA-AES256-GCM-SHA384  TLSv1.2 ...
ECDHE-RSA-AES256-GCM-SHA384    TLSv1.2 ...
```

Common DSL tokens:
- `ECDHE` — ECDHE key exchange
- `AESGCM` — AES in GCM mode
- `!` — exclude (e.g. `ALL:!aNULL:!MD5`)
- `@STRENGTH` — sort by key length

### Step 3: How many TLS 1.2 suites? And which TLS 1.3 suites?

```bash
$ openssl ciphers -v 'TLSv1.2' | wc -l
$ openssl ciphers -v | awk '$2 == "TLSv1.3"'
```

**Why:** `TLSv1.2` works as a version selector in the cipher-string DSL, but `'TLSv1.3'` does not — on OpenSSL 3.x, `openssl ciphers -v 'TLSv1.3'` fails with `Error in cipher list ... no cipher match`, because TLS 1.3 suites live outside the cipher-string DSL entirely (they're set with `-ciphersuites`; see Step 5). To see them, filter the default listing by its protocol column instead.

**Expected output:**
```
89
TLS_AES_256_GCM_SHA384         TLSv1.3 Kx=any      Au=any   Enc=AESGCM(256)            Mac=AEAD
TLS_CHACHA20_POLY1305_SHA256   TLSv1.3 Kx=any      Au=any   Enc=CHACHA20/POLY1305(256) Mac=AEAD
TLS_AES_128_GCM_SHA256         TLSv1.3 Kx=any      Au=any   Enc=AESGCM(128)            Mac=AEAD
```

(89 TLS 1.2 suites on OpenSSL 3.0.13 — the exact count is build-dependent. Three TLS 1.3 suites are enabled by default.)

### Step 4: Force a specific suite when connecting

If you have lesson 06's `s_server` running on :8443 (otherwise start it now: `bash certs/06-handshake/start-server.sh` in another terminal):

```bash
$ openssl s_client -connect 127.0.0.1:8443 -servername localhost -cipher 'ECDHE-RSA-AES256-GCM-SHA384' -tls1_2 </dev/null 2>&1 | grep '^New, TLS'
```

**Why:** `-cipher` constrains the ClientHello cipher list to your selection. `-tls1_2` forces the protocol version (since `-cipher` controls only TLS ≤ 1.2 suites).

**Expected output:**
```
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384
```

### Step 5: TLS 1.3 cipher selection (different flag)

```bash
$ openssl s_client -connect 127.0.0.1:8443 -servername localhost -ciphersuites 'TLS_CHACHA20_POLY1305_SHA256' -tls1_3 </dev/null 2>&1 | grep '^New, TLS'
```

**Why:** TLS 1.3 cipher suites use `-ciphersuites` (singular vs. plural reversed from `-cipher`) — a separate flag because the TLS 1.3 cipher namespace is unrelated to the older OpenSSL names.

**Expected output:**
```
New, TLSv1.3, Cipher is TLS_CHACHA20_POLY1305_SHA256
```

## Self-check

1. Why are TLS 1.3 suites listed with names starting `TLS_` while TLS 1.2 uses `ECDHE-RSA-...`?
2. What does `'ALL:!aNULL:!MD5:@STRENGTH'` evaluate to?
3. Why are `-cipher` and `-ciphersuites` separate flags instead of unified?

## Cross-references

- fixmycert.com: "Cipher String Decoder" — interactive DSL evaluator.
- Real-world bug this catches: nginx cipher list copy-pasted from a 2014 Mozilla guide; modern clients (TLS 1.3-only) refuse the connection because no overlapping suite.
- Related lessons: 06 (handshake basics), 10 (hostname is a separate concern from cipher).
