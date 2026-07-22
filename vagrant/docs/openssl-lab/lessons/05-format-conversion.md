# Lesson 05: Format conversion (PEM ↔ DER ↔ PKCS#12)

**Skill level:** intro
**Time:** ~10 min
**Prereqs:** Lesson 01

## Goal

Know which cert/key format each major tool wants and how to convert between them with single-flag openssl invocations.

## Setup

Uses files in `certs/05-formats/`:
- `cert.crt` — PEM-encoded self-signed cert
- `cert.key` — PEM-encoded private key

If you skipped bootstrap: `bash bootstrap.sh --only 05`

## Format quick-reference

| Format | Encoding | Extension(s) | Used by |
|--------|----------|--------------|---------|
| PEM    | base64 + ASCII headers | .crt, .pem, .cer | OpenSSL, nginx, Apache, most Linux tools |
| DER    | raw binary | .der, .cer | Java keystores, Windows (some), older protocols |
| PKCS#12 | binary container with cert + key + chain | .p12, .pfx | Windows, IIS, Java keystores, Apple Keychain |

## Walkthrough

### Step 1: PEM → DER

```bash
$ openssl x509 -in certs/05-formats/cert.crt -outform DER -out certs/05-formats/cert.der
```

**Why:** `-outform DER` writes raw binary instead of ASCII PEM. Used when feeding the cert to a tool that doesn't grok PEM (some Java APIs, old protocol bindings).

**Verify:**

```bash
$ file certs/05-formats/cert.crt certs/05-formats/cert.der
```

**Expected output:**
```
certs/05-formats/cert.crt: PEM certificate
certs/05-formats/cert.der: Certificate, Version=3
```

(Recent file(1) releases recognize both formats; older versions print
the generic `ASCII text` / `data` instead.)

### Step 2: DER → PEM (the reverse)

```bash
$ openssl x509 -in certs/05-formats/cert.der -inform DER -out certs/05-formats/round-trip.pem
```

**Why:** `-inform DER` tells openssl the input is binary. The default for both `-inform` and `-outform` is PEM, so you only specify when one side is DER.

**Verify the round-trip is bit-identical:**

```bash
$ diff <(openssl x509 -in certs/05-formats/cert.crt -text) <(openssl x509 -in certs/05-formats/round-trip.pem -text)
```

**Expected output:** no output (zero diff) — PEM and DER are two encodings of the same bytes.

### Step 3: Bundle cert + key into PKCS#12 (for Windows/IIS/Java)

```bash
$ openssl pkcs12 -export -inkey certs/05-formats/cert.key -in certs/05-formats/cert.crt -out certs/05-formats/cert.p12 -passout pass:lab
```

**Why:** `pkcs12 -export` builds a P12 archive bundling the private key (`-inkey`) and cert (`-in`). `-passout pass:lab` sets the archive encryption passphrase — use `pass:` only for lab; in production read from a file or env var.

**Verify it's a valid P12:**

```bash
$ openssl pkcs12 -info -in certs/05-formats/cert.p12 -nokeys -passin pass:lab
```

**Expected output:** prints the cert's PEM block + bag attributes. (`-nokeys` skips dumping the encrypted private key.)

### Step 4: Extract the cert back out of a P12

```bash
$ openssl pkcs12 -in certs/05-formats/cert.p12 -clcerts -nokeys -out certs/05-formats/extracted.crt -passin pass:lab
```

**Why:** `-clcerts` outputs only the client cert (no chain); `-nokeys` omits the private key.

**Verify:**

```bash
$ diff <(openssl x509 -in certs/05-formats/cert.crt -text) <(openssl x509 -in certs/05-formats/extracted.crt -text)
```

**Expected output:** zero diff.

## Self-check

1. Why is PKCS#12 password-protected by default but PEM keys aren't?
2. When would you choose DER over PEM in 2026?
3. What does `-clcerts` do, and how would the output change without it?

## Cross-references

- fixmycert.com: "PEM/DER/PKCS12" — interactive format converter.
- Real-world bug this catches: cert sent in PEM to a Java app that strictly wants DER → "javax.net.ssl.SSLException: Unsupported cert chain" — invisible until first connection.
- Related lessons: 13 (PEM bundles vs single certs).
