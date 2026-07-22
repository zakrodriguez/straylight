# Lesson 07: CRL inspection

**Skill level:** intermediate
**Time:** ~15 min
**Prereqs:** Lesson 02

## Goal

Read a Certificate Revocation List (CRL), check its freshness (`nextUpdate` field), and use it during chain validation (`verify -crl_check`).

## Setup

Uses files in `certs/07-crl/`:
- `ca.crt` — the CA that issued + revoked the leaf
- `leaf.crt`, `leaf.key` — a cert that is REVOKED in the CRL
- `lab.crl` — a fresh CRL listing the leaf's serial as revoked

If you skipped bootstrap: `bash bootstrap.sh --only 07`

## Walkthrough

### Step 1: Inspect the CRL

```bash
$ openssl crl -in certs/07-crl/lab.crl -text -noout
```

**Why:** parse the CRL to human-readable text. Look for the `Revoked Certificates` section.

**Expected output (key lines):**
```
Certificate Revocation List (CRL):
        Issuer: CN = Lab CA
        Last Update: ...
        Next Update: ...   <-- this is the freshness deadline
Revoked Certificates:
    Serial Number: 1000
        Revocation Date: ...
```

### Step 2: Just the dates (freshness check)

```bash
$ openssl crl -in certs/07-crl/lab.crl -lastupdate -nextupdate -noout
```

**Why:** when monitoring a CRL endpoint, you only care about the next-update timestamp. If `now > nextUpdate`, the CRL is stale and consumers may reject the chain.

**Expected output:**
```
lastUpdate=...
nextUpdate=...
```

### Step 3: Verify the leaf — without -crl_check (revocation ignored)

```bash
$ openssl verify -CAfile certs/07-crl/ca.crt certs/07-crl/leaf.crt
```

**Why:** baseline. By default, `verify` does NOT consult any CRLs. The leaf appears OK because chain-of-trust math works.

**Expected output:**
```
certs/07-crl/leaf.crt: OK
```

### Step 4: Verify the leaf — with -crl_check (revocation enforced)

```bash
$ openssl verify -CAfile certs/07-crl/ca.crt -CRLfile certs/07-crl/lab.crl -crl_check certs/07-crl/leaf.crt
```

**Why:** `-crl_check` enforces CRL checking for the leaf; `-CRLfile <crl>` supplies the CRL. openssl finds the leaf's serial in the revoked list and refuses.

**Expected output:**
```
CN = will-be-revoked.example.com
error 23 at 0 depth lookup: certificate revoked
error certs/07-crl/leaf.crt: verification failed
```

**Error 23 = "certificate revoked"** — the failure that matters here.

### Step 5: Why nextUpdate matters — simulate stale CRL handling

```bash
$ next=$(openssl crl -in certs/07-crl/lab.crl -nextupdate -noout | cut -d= -f2)
$ now=$(date -u +"%b %e %H:%M:%S %Y GMT")
$ echo "nextUpdate: $next"
$ echo "now:        $now"
```

**Why:** clients (browsers, app servers) cache CRLs and ignore them once `nextUpdate` passes. A CA that fails to publish fresh CRLs ships a hidden outage — clients silently fall back to "no revocation info" and accept revoked certs. Monitoring `nextUpdate` is the operational job here.

## Self-check

1. Why does the default behavior of `verify` skip CRL checking?
2. If `nextUpdate` has passed, what should a strict client do?
3. How would you verify the CRL itself was signed by the right CA (vs. trusting it blindly)?

## Cross-references

- fixmycert.com: "CRL Lifecycle" — animation of issue → revoke → publish CRL → client check.
- Real-world bug this catches: CA publishing pipeline broke; CRL stale for 3 days; clients silently accepting revoked certs in that window.
- Related lessons: 08 (OCSP — the alternative to polling CRLs), 02 (chain verify basics).
