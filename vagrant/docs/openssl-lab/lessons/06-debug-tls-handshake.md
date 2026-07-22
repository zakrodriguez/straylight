# Lesson 06: Debug a TLS handshake

**Skill level:** intermediate
**Time:** ~20 min
**Prereqs:** Lesson 02

## Goal

Use `openssl s_client` to drive a TLS handshake against any server and read the result: which cert chain was sent, whether it validates, and which cipher suite + protocol version was negotiated.

## Setup

Uses files in `certs/06-handshake/`:
- `server.crt`, `server.key` — server cert (self-signed) for `localhost`
- `start-server.sh` — convenience launcher for `openssl s_server`

If you skipped bootstrap: `bash bootstrap.sh --only 06`

**Open a second terminal** and run the server in it (it stays foreground):

```bash
$ bash certs/06-handshake/start-server.sh
```

It prints a startup banner (exact text varies by OpenSSL build) and waits for connections. Leave it running; all `s_client` commands below run in your original terminal.

## Walkthrough

### Step 1: Basic handshake (expect a verify failure — self-signed)

```bash
$ openssl s_client -connect 127.0.0.1:8443 -servername localhost </dev/null 2>&1 | head -60
```

**Why:**
- `-connect host:port`: TCP target.
- `-servername`: SNI value sent in ClientHello. Always set this — many servers reject connections without SNI.
- `</dev/null`: closes stdin so s_client exits after the handshake instead of waiting for you to type HTTP.
- `2>&1 | head -60`: combine stdout+stderr (s_client mixes both), trim to the first 60 lines — enough to reach the summary block, which sits after the server's PEM dump.

**Expected output (key lines):**
```
depth=0 CN = localhost
verify error:num=18:self-signed certificate
verify return:1
...
SSL handshake has read ... and written ...
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 2048 bit
Verify return code: 18 (self-signed certificate)
```

### Step 2: Read the negotiated cipher + protocol

```bash
$ openssl s_client -connect 127.0.0.1:8443 -servername localhost </dev/null 2>&1 | grep -E '^(New, TLS|Verify return code|Server public key)'
```

**Why:** the `New,` line — `New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384` — gives the protocol version + cipher suite the server agreed to.

**Expected output:**
```
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Server public key is 2048 bit
Verify return code: 18 (self-signed certificate)
```

### Step 3: See the cert chain the server sent (-showcerts)

```bash
$ openssl s_client -connect 127.0.0.1:8443 -servername localhost -showcerts </dev/null 2>&1 | grep -E '(s:|i:|^ ?-+BEGIN)' | head -10
```

**Why:** `-showcerts` makes s_client print every cert in the server's chain (PEM + subject + issuer). Filter for `s:` (subject), `i:` (issuer), and PEM headers.

**Expected output:**
```
 0 s:CN = localhost
   i:CN = localhost
-----BEGIN CERTIFICATE-----
```

(Only one cert because it's self-signed; a real server would show multiple.)

### Step 4: Trust the self-signed cert + verify validates

```bash
$ openssl s_client -connect 127.0.0.1:8443 -servername localhost -CAfile certs/06-handshake/server.crt </dev/null 2>&1 | grep 'Verify return code'
```

**Why:** `-CAfile` adds the server's own cert as a trust anchor (only useful for lab/test). Now the chain validates.

**Expected output:**
```
Verify return code: 0 (ok)
```

### Step 5: Force a specific TLS version

```bash
$ openssl s_client -connect 127.0.0.1:8443 -servername localhost -tls1_2 </dev/null 2>&1 | grep -E 'New, TLS|Verify return code'
```

**Why:** `-tls1_2`, `-tls1_3` (and historic `-tls1_1`, `-tls1`) force the version. Useful for "does the server support TLS 1.2?" probes. The grep is unanchored because in a TLS 1.2 session the verify code only appears indented inside the `SSL-Session:` block.

**Expected output:**
```
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384
    Verify return code: 18 (self-signed certificate)
```

### Step 6: Stop the server

In the SECOND terminal where `start-server.sh` is running, press `Ctrl-C`.

## Self-check

1. Why does `-servername` matter even when you only have one cert on the server?
2. What's the difference between `verify error:num=18` (during handshake) and `Verify return code: 18` (at the end)?
3. If the server requires TLS 1.3 and you `-tls1_2`, what error do you expect?

## Cross-references

- fixmycert.com: "TLS Handshake Visualizer" — animated walkthrough of ClientHello → ServerHello → CertificateVerify.
- Real-world bug this catches: server has TLS 1.0 enabled by mistake → modern clients refuse with "no protocols available". `s_client -tls1` quickly proves the regression.
- Related lessons: 10 (hostname mismatch — same `s_client` command, different verify error), 11 (cipher suite control).
