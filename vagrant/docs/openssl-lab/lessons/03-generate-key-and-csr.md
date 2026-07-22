# Lesson 03: Generate a private key + CSR

**Skill level:** intro
**Time:** ~15 min
**Prereqs:** Lesson 01

## Goal

Create a 2048-bit RSA private key and a Certificate Signing Request
(CSR) from a config file (vs. interactive prompts), and understand why
the config-file approach is the only sane one for real workflows.

## Setup

Uses files in `certs/03-csr/`:
- `req.conf` — pre-baked CSR template

If you skipped bootstrap: `bash bootstrap.sh --only 03`

## Walkthrough

### Step 1: Generate a 2048-bit RSA private key

```bash
$ openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out certs/03-csr/api.key
```

**Why:**
- `genpkey` is the modern key-generation command (replaces older `genrsa`).
- `-algorithm RSA`: pick the algo. Could also be `EC` (with `-pkeyopt ec_paramgen_curve:P-256`) or `Ed25519` (no opts needed).
- `-pkeyopt rsa_keygen_bits:2048`: 2048 is the modern minimum for RSA; 4096 for higher-security use.
- `-out`: output file. The key is unencrypted. To password-protect, add `-aes256 -pass pass:foo` (don't use `pass:` in production — read from a file or env var).

**Expected output:** silent success; check the file:

```bash
$ openssl pkey -in certs/03-csr/api.key -text -noout | head -3
```

Should print `Private-Key: (2048 bit, 2 primes)`.

### Step 2: Inspect the config file we'll use

```bash
$ cat certs/03-csr/req.conf
```

**Why:** the config file declares the subject DN, the requested SANs, and the requested key usage. Pre-defining these in a file means:
- Reproducible builds (the same `req.conf` always produces the same DN).
- No interactive `Common Name (e.g. server FQDN) []:` prompts in CI.
- Multiple SANs work (impossible to enter via the interactive prompt sanely).

### Step 3: Generate the CSR

```bash
$ openssl req -new -key certs/03-csr/api.key -out certs/03-csr/api.csr -config certs/03-csr/req.conf
```

**Why:**
- `req -new`: create a new CSR.
- `-key <file>`: use this private key (don't generate a new one).
- `-config <file>`: use this config (vs. the system default `/etc/ssl/openssl.cnf`).

**Expected output:** silent success.

### Step 4: Inspect the CSR (sanity check before sending to a CA)

```bash
$ openssl req -in certs/03-csr/api.csr -text -noout
```

**Expected output (key lines):**
```
        Subject: CN = api.example.com, O = Example Org, C = US
        Subject Public Key Info:
            Public Key Algorithm: rsaEncryption
                Public-Key: (2048 bit)
        Requested Extensions:
            X509v3 Subject Alternative Name:
                DNS:api.example.com, DNS:api-staging.example.com
            X509v3 Key Usage: critical
                Digital Signature, Key Encipherment
            X509v3 Extended Key Usage:
                TLS Web Server Authentication
```

### Step 5: Verify the CSR's signature is internally consistent

```bash
$ openssl req -in certs/03-csr/api.csr -verify -noout
```

**Why:** a CSR is signed by the private key matching its embedded public key ("proof of possession"); this checks that the signature validates against that public key. CAs always do this before issuing.

**Expected output:**
```
Certificate request self-signature verify OK
```

## Self-check

1. Why use `-config req.conf` instead of letting openssl prompt?
2. What does `Requested Extensions` mean in the CSR — are they guaranteed to appear in the issued cert?
3. How would you change the config to request a P-256 ECDSA key instead of RSA?

## Cross-references

- fixmycert.com: "CSR Walkthrough" — interactive form for building a CSR.
- Real-world bug this catches: CSR submitted to a CA missing a SAN (CA template usually doesn't infer SANs from CN; you must explicitly request them).
- Related lessons: 04 (sign this CSR yourself), 09 (the extensions the CSR requests are revisited).
