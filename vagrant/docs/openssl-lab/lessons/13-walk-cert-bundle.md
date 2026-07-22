# Lesson 13: Walk a cert bundle

**Skill level:** advanced
**Time:** ~20 min
**Prereqs:** Lessons 02, 05

## Goal

Split a multi-cert PEM bundle into individual certs, inspect each, and understand why some clients (curl, Java, Go) treat bundle ORDER differently.

## Setup

Uses files in `certs/13-bundle/`:
- `chain.pem` — leaf + intermediate concatenated (standard "send to client" bundle)
- `root.crt` — the root CA (NOT in the bundle, by convention)

If you skipped bootstrap: `bash bootstrap.sh --only 13`

## Walkthrough

### Step 1: How many certs are in the bundle?

```bash
$ grep -c 'BEGIN CERTIFICATE' certs/13-bundle/chain.pem
```

**Expected output:**
```
2
```

### Step 2: Split the bundle into separate files using awk

```bash
$ awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} {print > sprintf("/tmp/bundle-cert-%d.pem", n)}' certs/13-bundle/chain.pem
$ ls /tmp/bundle-cert-*.pem
```

**Why:** the awk pattern increments `n` at each cert header and prints every line into the current per-cert file.

**Expected output:**
```
/tmp/bundle-cert-1.pem
/tmp/bundle-cert-2.pem
```

### Step 3: Inspect each cert in order

```bash
$ for f in /tmp/bundle-cert-*.pem; do
    echo "=== $f ==="
    openssl x509 -in "$f" -subject -issuer -noout
  done
```

**Expected output:**
```
=== /tmp/bundle-cert-1.pem ===
subject=CN = leaf.example.com, O = Example Org
issuer=CN = Lab Intermediate CA, O = Example Org
=== /tmp/bundle-cert-2.pem ===
subject=CN = Lab Intermediate CA, O = Example Org
issuer=CN = Lab Root CA, O = Example Org
```

The bundle's first cert is the LEAF. The second cert is the INTERMEDIATE that signed it.

### Step 4: Verify the bundle as a chain

```bash
$ openssl verify -CAfile certs/13-bundle/root.crt -untrusted certs/13-bundle/chain.pem /tmp/bundle-cert-1.pem
```

**Why:** `-untrusted` accepts the bundle file. The leaf appears in both `-untrusted` and the positional arg — openssl deduplicates.

**Expected output:**
```
/tmp/bundle-cert-1.pem: OK
```

### Step 5: Order matters for some clients (the "wrong order" demo)

```bash
$ # Build a deliberately mis-ordered bundle: intermediate first, leaf second.
$ cat /tmp/bundle-cert-2.pem /tmp/bundle-cert-1.pem > /tmp/bundle-misordered.pem
$ # Re-run verify — does openssl care?
$ openssl verify -CAfile certs/13-bundle/root.crt -untrusted /tmp/bundle-misordered.pem /tmp/bundle-cert-1.pem
```

**Expected output:**
```
/tmp/bundle-cert-1.pem: OK
```

OpenSSL's `verify` doesn't care about order — it just reads the bundle as a candidate pool. **But** in real TLS handshakes:
- **nginx, Apache, IIS** send the bundle to the client EXACTLY as configured. If the client is a strict implementation that walks the chain in order (Java JSSE in older versions, some Go versions), wrong order breaks the handshake.
- **OpenSSL itself + curl + most browsers** are lenient.

The convention: leaf first, then intermediate(s) in chain order, no root.

### Step 6: Cleanup

```bash
$ rm -f /tmp/bundle-cert-*.pem /tmp/bundle-misordered.pem
```

## Self-check

1. Why does the convention exclude the root from the bundle?
2. If openssl is lenient about order, why does anyone care?
3. How would you produce a bundle suitable for `nginx ssl_certificate` from `chain.pem` + `leaf.key`?

## Cross-references

- fixmycert.com: "Bundle Order Matters" — animation of strict vs. lenient client handling.
- Real-world bug this catches: nginx config has `intermediate.crt; leaf.crt;` (wrong order) — most browsers work, Java app stops working after a JVM upgrade.
- Related lessons: 02 (chain verification basics), 05 (PEM bundle is just concatenation).
