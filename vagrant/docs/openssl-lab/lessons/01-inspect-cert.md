# Lesson 01: Inspect a cert

**Skill level:** intro
**Time:** ~10 min
**Prereqs:** none

## Goal

Read any X.509 certificate's subject, issuer, dates, fingerprint,
public key algorithm, and SANs without dumping the raw PEM.

## Setup

Uses files in `certs/01-inspect/` (created by `bootstrap.sh`).
If you skipped bootstrap: `bash bootstrap.sh --only 01`

The cert is a self-signed leaf with three SANs (two DNS + one IP) and 365-day validity.

## Walkthrough

### Step 1: Full text dump (the everything view)

```bash
$ openssl x509 -in certs/01-inspect/leaf.crt -text -noout
```

**Why:**
- `-in <file>`: input certificate (PEM by default).
- `-text`: human-readable parsed output (subject, issuer, dates, key, extensions).
- `-noout`: suppress the wall of base64 PEM that would otherwise print below the human-readable output.

**Expected output (key lines):**
```
        Issuer: CN = leaf.example.com, O = Example Org
        Subject: CN = leaf.example.com, O = Example Org
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
            X509v3 Subject Alternative Name:
                DNS:leaf.example.com, DNS:www.example.com, IP Address:10.0.0.42
```

### Step 2: Just the dates

```bash
$ openssl x509 -in certs/01-inspect/leaf.crt -dates -noout
```

**Why:** `-dates` prints just `notBefore=` and `notAfter=` — enough to answer "is this cert expired or about to be?" without the full `-text` dump.

**Expected output:**
```
notBefore=...
notAfter=...
```

### Step 3: Fingerprint (for cert-pinning + identification)

```bash
$ openssl x509 -in certs/01-inspect/leaf.crt -fingerprint -sha256 -noout
```

**Why:**
- `-fingerprint`: SHA-1 by default; `-sha256` switches to SHA-256 (modern preference).
- The fingerprint is a hash of the cert's DER encoding — uniquely identifies the cert without revealing the key.

**Expected output:**
```
sha256 Fingerprint=XX:XX:XX:...:XX:XX
```

### Step 4: Just the subject and issuer

```bash
$ openssl x509 -in certs/01-inspect/leaf.crt -subject -issuer -noout
```

**Why:** quick sanity check for "who issued this and to whom". For self-signed certs, subject == issuer.

**Expected output:**
```
subject=CN = leaf.example.com, O = Example Org
issuer=CN = leaf.example.com, O = Example Org
```

## Self-check

1. The cert has three SANs. How would you extract ONLY the SAN line from the `-text` dump? (Hint: `grep -A1 'Subject Alternative Name'`.)
2. What's the difference in output between `openssl x509 -in cert.crt` (no flags) vs `-in cert.crt -text -noout`?
3. Why does `-noout` matter here but doesn't matter for `-fingerprint`?

## Cross-references

- fixmycert.com: "Decode This Certificate" — same concept, drag-and-drop.
- Real-world bug this catches: cert deployed without the expected SAN — the IIS bind succeeds but browsers reject with `NET::ERR_CERT_COMMON_NAME_INVALID`.
- Related lessons: 09 (decode SAN + EKU extensions in depth), 10 (hostname mismatch diagnosis).
