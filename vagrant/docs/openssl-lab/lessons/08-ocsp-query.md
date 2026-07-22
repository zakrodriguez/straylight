# Lesson 08: OCSP query

**Skill level:** intermediate
**Time:** ~20 min
**Prereqs:** Lessons 02, 07

## Goal

You'll know how OCSP differs from CRLs (single-cert query vs. full list)
and how to query a responder with the openssl client.

## Setup

Uses files in `certs/08-ocsp/`:
- `issuer.crt`, `issuer.key` — the issuing CA (also used to sign OCSP responses)
- `leaf.crt`, `leaf.key` — a cert whose status we'll query

> **Note on the issuer CN:** lesson 07 never exposes its CA private key, and
> the OCSP responder needs a key to sign responses, so `bootstrap.sh` generates
> a small standalone CA for this lesson — `issuer.crt` shows a subject like
> `CN = Lab OCSP CA` rather than the lesson-07 `Lab CA`.
- `index.txt` — the responder's status database (V/R flags per serial)
- `start-responder.sh` — launcher for `openssl ocsp` in responder mode

If you skipped bootstrap: `bash bootstrap.sh --only 08`

**Open a second terminal** and start the responder:

```bash
$ bash certs/08-ocsp/start-responder.sh
```

It prints `ocsp: waiting for OCSP client connections...` and stays
foreground. All OCSP client commands below run in your original terminal.

## Walkthrough

### Step 1: Query the status of the leaf cert

```bash
$ openssl ocsp -issuer certs/08-ocsp/issuer.crt -cert certs/08-ocsp/leaf.crt -url http://127.0.0.1:8888 -resp_text -noverify 2>&1 | head -20
```

**Why:**
- `-issuer`: the cert that signed the leaf (OCSP requests are scoped to a single issuer).
- `-cert`: the cert whose status we're asking about.
- `-url`: the responder URL.
- `-resp_text`: print the parsed response (vs. just exit code).
- `-noverify`: skip verifying the responder's signature for now (Step 3 covers it).

**Expected output (key lines):**
```
OCSP Response Data:
    OCSP Response Status: successful (0x0)
    Response Type: Basic OCSP Response
...
    Cert Status: good
    This Update: ...
```

(No `Next Update` line — the lab responder doesn't set a validity interval.)

### Step 2: Mark the cert revoked + re-query

```bash
$ rev=$(date -u +%y%m%d%H%M%SZ)
$ sed -i.bak "s/^V\t\([^\t]*\)\t\t/R\t\1\t${rev}\t/" certs/08-ocsp/index.txt
$ cat certs/08-ocsp/index.txt
```

(The `\t` escapes need GNU sed; on macOS use Homebrew `gsed`, or hand-edit
the file — change the leading `V` to `R` and put the timestamp between the
two adjacent tabs.)

`index.txt` is a tab-separated CA database: status, expiry,
revocation-time, serial, filename, subject. Revoking an entry needs BOTH
the `V` → `R` flip in field 1 AND a `YYMMDDHHMMSSZ` timestamp in the
(empty) revocation-time field 3 — an `R` row with an empty revocation
time makes the responder answer `Responder Error: internalerror (2)`
(`invalid revocation date` in its log) and exit.

**Expected output** (your dates/serial will differ):
```
R	260812224006Z	260718211218Z	21FB10C0E2176C1F9D8E12F68A338F59809BB518	unknown	/CN=ocsp-test.example.com
```

**Restart the responder:** `openssl ocsp` loads `index.txt` once at
startup and caches it — a query after the edit still returns
`Cert Status: good`. In the second terminal, `Ctrl-C` and re-run
`bash certs/08-ocsp/start-responder.sh`, then re-query:

```bash
$ openssl ocsp -issuer certs/08-ocsp/issuer.crt -cert certs/08-ocsp/leaf.crt -url http://127.0.0.1:8888 -noverify
```

**Expected output:**
```
certs/08-ocsp/leaf.crt: revoked
	This Update: ...
	Revocation Time: ...
```

### Step 3: Verify the responder's signature

```bash
$ openssl ocsp -issuer certs/08-ocsp/issuer.crt -cert certs/08-ocsp/leaf.crt -url http://127.0.0.1:8888 -CAfile certs/08-ocsp/issuer.crt 2>&1 | tail -5
```

**Why:** drop `-noverify` and add `-CAfile` so openssl verifies the OCSP response is signed by a trusted issuer (here the same CA). In production, OCSP responders often have their own dedicated signing cert with the OCSPSigning EKU.

**Expected output:**
```
Response verify OK
certs/08-ocsp/leaf.crt: revoked
	This Update: ...
	Revocation Time: ...
```

### Step 4: Restore the cert to "good" + Stop the responder

```bash
$ mv certs/08-ocsp/index.txt.bak certs/08-ocsp/index.txt
```

In the second terminal where `start-responder.sh` is running, press
`Ctrl-C`. (If you want to re-query the restored "good" status instead,
restart the responder first — it still holds the revoked table.)

## Self-check

1. Why does OCSP scale better than CRLs for large CAs?
2. What's "OCSP stapling" and why was it invented?
3. Why does an OCSP query NEED the issuer cert (not just the cert being checked)?

## Cross-references

- fixmycert.com: "OCSP vs CRL" — side-by-side comparison.
- Real-world bug this catches: CA's OCSP responder stops responding (network outage); browsers fall back to "soft fail" and accept revoked certs silently.
- Related lessons: 07 (CRLs — the alternative), 02 (chain verify primer).
