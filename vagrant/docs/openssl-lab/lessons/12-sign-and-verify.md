# Lesson 12: Sign + verify a payload

**Skill level:** advanced
**Time:** ~15 min
**Prereqs:** Lesson 03

## Goal

Sign a file with a private key using `openssl dgst`, and verify the signature with the corresponding public key.

## Setup

Uses files in `certs/12-sign/`:
- `priv.key` — RSA-2048 private key
- `pub.key` — extracted public key
- `payload.txt` — the message we'll sign

If you skipped bootstrap: `bash bootstrap.sh --only 12`

## Walkthrough

### Step 1: Sign the payload

```bash
$ openssl dgst -sha256 -sign certs/12-sign/priv.key -out certs/12-sign/sig.bin certs/12-sign/payload.txt
```

**Why:**
- `dgst -sha256`: compute SHA-256 hash, then sign the hash. (Sign-the-hash is the universal pattern; signing the raw payload would be unsafe and slow.)
- `-sign <privkey>`: sign with this private key.
- `-out sig.bin`: signature output (binary). To get base64 for a JSON payload, pipe through `base64 -w0`.

**Expected output:** silent success; produces `sig.bin` (~256 bytes for RSA-2048).

```bash
$ ls -la certs/12-sign/sig.bin
```

### Step 2: Verify the signature

```bash
$ openssl dgst -sha256 -verify certs/12-sign/pub.key -signature certs/12-sign/sig.bin certs/12-sign/payload.txt
```

**Why:**
- `-verify <pubkey>`: verify mode. Reads the public key from this file.
- `-signature <file>`: the signature blob to check.
- The remaining positional arg is the payload — must be the EXACT bytes that were signed (re-hashed during verify).

**Expected output:**
```
Verified OK
```

### Step 3: What happens if the payload is tampered with?

```bash
$ echo " (tampered)" >> certs/12-sign/payload.txt
$ openssl dgst -sha256 -verify certs/12-sign/pub.key -signature certs/12-sign/sig.bin certs/12-sign/payload.txt
```

**Expected output:**
```
Verification failure
```

(`dgst -verify` exits non-zero on failure.)

### Step 4: Restore the payload

```bash
$ echo "important-message-2026" > certs/12-sign/payload.txt
$ openssl dgst -sha256 -verify certs/12-sign/pub.key -signature certs/12-sign/sig.bin certs/12-sign/payload.txt
```

**Expected output:**
```
Verified OK
```

### Step 5: Note about hash algorithm and key choice

The hash algorithm in `-sha256` MUST match for sign and verify: a `-sha512` signer with a `-sha256` verifier fails even with correct keys.

For ECDSA + Ed25519, the choice differs:
- ECDSA P-256: pair with SHA-256 (`-sha256`).
- Ed25519: doesn't take a hash flag; `openssl pkeyutl -sign` is the modern command.

## Self-check

1. Why hash-then-sign instead of sign-the-payload directly?
2. What's the difference between a digital signature and a MAC?
3. Why does the signature blob have a fixed size for RSA-2048 (256 bytes)?

## Cross-references

- fixmycert.com: "Signature Verification" — interactive sign/verify demo.
- Real-world bug this catches: signing pipeline emits SHA-256 signatures, verifier configured for SHA-512 → silent verification failures masked as "config drift."
- Related lessons: 03 (CSRs are a special case of signed-payload), 04 (cert signing is a signed payload too).
