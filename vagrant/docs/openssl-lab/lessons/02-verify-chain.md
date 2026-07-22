# Lesson 02: Verify a cert chain

**Skill level:** intro
**Time:** ~15 min
**Prereqs:** Lesson 01

## Goal

Understand the trust anchor model, validate a 3-tier chain (root →
intermediate → leaf) with `openssl verify`, and decode common verify error codes.

## Setup

Uses files in `certs/02-chain/`:
- `root.crt`, `intermediate.crt`, `leaf.crt` — separate certs
- `chain.pem` — leaf + intermediate concatenated (standard "send to client" bundle)

If you skipped bootstrap: `bash bootstrap.sh --only 02`

## Walkthrough

### Step 1: Successful verify (full chain provided)

```bash
$ openssl verify -CAfile certs/02-chain/root.crt -untrusted certs/02-chain/intermediate.crt certs/02-chain/leaf.crt
```

**Why:**
- `-CAfile <root>`: the trust anchor. `verify` only trusts certs that ultimately chain up to this.
- `-untrusted <intermediate>`: certs to consider when building the chain, but NOT trusted as anchors. Intermediates always go here.
- `<leaf>`: the cert being verified.

**Expected output:**
```
certs/02-chain/leaf.crt: OK
```

### Step 2: Failure — missing intermediate (the most common real-world bug)

```bash
$ openssl verify -CAfile certs/02-chain/root.crt certs/02-chain/leaf.crt
```

**Why:** without `-untrusted`, openssl can't bridge from leaf → intermediate → root. It fails at the first jump.

**Expected output:**
```
CN = leaf.example.com, O = Example Org
error 20 at 0 depth lookup: unable to get local issuer certificate
error certs/02-chain/leaf.crt: verification failed
```

**Error 20 = "unable to get local issuer certificate"** — openssl knows the leaf's declared issuer (the intermediate's subject) but finds no cert with that subject in the trusted or untrusted stores.

### Step 3: Verify using a chain bundle as -untrusted source

```bash
$ openssl verify -CAfile certs/02-chain/root.crt -untrusted certs/02-chain/chain.pem certs/02-chain/leaf.crt
```

**Why:** `-untrusted` accepts a bundle of concatenated PEMs. The leaf appears twice (in the bundle and as the verify target) — fine; openssl deduplicates by fingerprint.

**Expected output:**
```
certs/02-chain/leaf.crt: OK
```

### Step 4: Print the chain that verify built (-show_chain)

```bash
$ openssl verify -CAfile certs/02-chain/root.crt -untrusted certs/02-chain/intermediate.crt -show_chain certs/02-chain/leaf.crt
```

**Why:** `-show_chain` prints each cert in the built chain by depth. Useful when you suspect openssl picked the WRONG intermediate (e.g. when you have multiple cross-signed intermediates).

**Expected output:**
```
certs/02-chain/leaf.crt: OK
Chain:
depth=0: CN = leaf.example.com, O = Example Org (untrusted)
depth=1: CN = Lab Intermediate CA, O = Example Org (untrusted)
depth=2: CN = Lab Root CA, O = Example Org
```

## Self-check

1. What's the difference between `-CAfile` and `-untrusted`?
2. If `verify` reports `error 18 at 0 depth lookup: self-signed certificate`, what does it mean and what would you do?
3. Why does the "chain bundle" convention NOT include the root cert?

## Cross-references

- fixmycert.com: "Chain of Trust Builder" — drag intermediates into a chain visually.
- Real-world bug this catches: web server configured with leaf-only cert (forgot to bundle intermediate). Browsers cache the intermediate after the first visit, so the bug shows up only for new users — classic "works on my machine" trap.
- Related lessons: 13 (walk a cert bundle), 06 (TLS handshake also exercises chain validation).
