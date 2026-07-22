# Lesson 10: Hostname mismatch diagnosis

**Skill level:** intermediate
**Time:** ~15 min
**Prereqs:** Lesson 06

## Goal

You'll know how to use `s_client -verify_hostname` to diagnose
"wrong cert for this hostname" issues — distinct from chain-of-trust
errors, and one of the most common production cert problems.

## Setup

Uses files in `certs/10-hostname/`:
- `server.crt`, `server.key` — server cert with ONE SAN: `correct-name.example.com`
- `start-server.sh` — launcher

If you skipped bootstrap: `bash bootstrap.sh --only 10`

**Open a second terminal** and run the server:

```bash
$ bash certs/10-hostname/start-server.sh
```

(Listens on 127.0.0.1:8444. Different port from lesson 06 so they can run side by side.)

## Walkthrough

### Step 1: Connect with the WRONG expected hostname

```bash
$ openssl s_client -connect 127.0.0.1:8444 -servername wrong-name.example.com -verify_hostname wrong-name.example.com -CAfile certs/10-hostname/server.crt </dev/null 2>&1 | grep -E '^(Verify|verify error)'
```

**Why:**
- `-servername`: the SNI value sent (what hostname the client claims to want).
- `-verify_hostname`: have the openssl verify hook check the cert's SAN/CN against this name.
- `-CAfile`: trust the self-signed cert as a CA so the chain validates and the failure is purely about hostname.

**Expected output:**
```
verify error:num=62:hostname mismatch
Verify return code: 62 (hostname mismatch)
```

**Error 62 = hostname mismatch** — the chain is valid, but the cert wasn't issued for this hostname.

### Step 2: Connect with the RIGHT expected hostname

```bash
$ openssl s_client -connect 127.0.0.1:8444 -servername correct-name.example.com -verify_hostname correct-name.example.com -CAfile certs/10-hostname/server.crt </dev/null 2>&1 | grep -E '^Verify return code'
```

**Expected output:**
```
Verify return code: 0 (ok)
```

### Step 3: Confirm what hostnames the cert actually allows

```bash
$ openssl x509 -in certs/10-hostname/server.crt -ext subjectAltName -noout
```

**Expected output:**
```
X509v3 Subject Alternative Name:
    DNS:correct-name.example.com
```

If you see ONLY a CN and no SAN, modern browsers (Chrome, Firefox) reject the cert for any hostname — even one matching the CN. CN-only matching was deprecated for TLS in RFC 6125 and Chrome enforced it in 58 (2017).

### Step 4: Wildcard SAN — what matches?

Wildcard rules:
- `*.example.com` matches `foo.example.com`, `bar.example.com`. Does NOT match `example.com` (the apex) and does NOT match `foo.bar.example.com` (multi-level).
- `*` only allowed in the leftmost label. `foo.*.example.com` is invalid.
- `*.*.example.com` is invalid (only one wildcard).

No openssl flag enumerates these rules — they're facts to memorize.

### Step 5: Stop the server

`Ctrl-C` in the second terminal.

## Self-check

1. What's the difference between `-servername` and `-verify_hostname`?
2. If a cert has `subject=CN=foo.example.com` but no SAN, what happens with a modern browser?
3. Will `*.example.com` match `example.com`?

## Cross-references

- fixmycert.com: "Why Doesn't This Validate?" — hostname mismatch is the #1 case.
- Real-world bug this catches: cert renewed but the new SAN list dropped a hostname (typo in the CSR config). Clients hitting that hostname start failing 12 hours later when DNS-cached old cert expires.
- Related lessons: 09 (SAN structure), 06 (handshake debug primer).
