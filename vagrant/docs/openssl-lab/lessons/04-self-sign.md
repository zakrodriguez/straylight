# Lesson 04: Self-sign a cert

**Skill level:** intro
**Time:** ~10 min
**Prereqs:** Lesson 03

## Goal

Two ways to self-sign a cert (one-shot and CSR-based), and when to use each.

## Setup

Uses files in `certs/04-selfsign/`:
- `devbox.key` — pre-generated private key
- `devbox.csr` — pre-generated CSR for `devbox.local`
- `req.conf` — config file used to make the CSR (you'll reuse it in Step 1)

If you skipped bootstrap: `bash bootstrap.sh --only 04`

## Walkthrough

### Step 1: Method A — one-shot self-sign (key + cert in one command)

```bash
$ openssl req -x509 -key certs/04-selfsign/devbox.key -out certs/04-selfsign/method-a.crt -days 90 -config certs/04-selfsign/req.conf -extensions ext
```

**Why:**
- `req -x509`: instead of producing a CSR, produce a self-signed cert directly.
- `-key`: use this existing key (otherwise `req -newkey` would generate one).
- `-days 90`: validity. For dev/test certs, keep it short.
- `-config + -extensions`: same config the CSR used; here it provides the SAN.

**Expected output:** silent success.

### Step 2: Method B — sign an existing CSR

```bash
$ openssl x509 -req -in certs/04-selfsign/devbox.csr -signkey certs/04-selfsign/devbox.key -days 90 -out certs/04-selfsign/method-b.crt -extfile certs/04-selfsign/req.conf -extensions ext
```

**Why:**
- `x509 -req`: this `x509` invocation reads a CSR (via `-req`) and writes a cert.
- `-signkey`: sign the cert using this key. Since the CSR's public key matches this private key, the result is self-signed.
- `-extfile + -extensions ext`: x509 doesn't pull extensions from the CSR by default — you have to point it at the same config that built the CSR.

**Expected output:**
```
Certificate request self-signature ok
subject=CN = devbox.local
```

### Step 3: Compare the two outputs (they should be near-identical)

```bash
$ openssl x509 -in certs/04-selfsign/method-a.crt -subject -issuer -dates -noout
$ openssl x509 -in certs/04-selfsign/method-b.crt -subject -issuer -dates -noout
```

**Expected output:** identical subject + issuer + matching `notBefore`/`notAfter` (within a second or two).

### Step 4: Confirm Method B picked up the SAN extension

```bash
$ openssl x509 -in certs/04-selfsign/method-b.crt -ext subjectAltName -noout
```

**Expected output:**
```
X509v3 Subject Alternative Name:
    DNS:devbox.local, DNS:localhost, IP Address:127.0.0.1
```

Omit `-extfile`/`-extensions` in Step 2 and the cert ships without the SAN — a classic gotcha.

## Self-check

1. When would you use Method A vs. Method B?
2. Why does `x509 -req` need `-extfile` even when the CSR already has Requested Extensions?
3. The output cert is valid for 90 days. What changes if you pass `-days 0`?

## Cross-references

- fixmycert.com: "Quick Self-Signed" — interactive form.
- Real-world bug this catches: dev team self-signs with `x509 -req` and forgets `-extfile`; cert appears valid but browsers reject because SAN is missing.
- Related lessons: 03 (where the CSR came from), 09 (extensions in depth).
