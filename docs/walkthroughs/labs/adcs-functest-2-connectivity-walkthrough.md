# ADCS Functional Test Lab 2 — Enrollment Interface & CA Exchange Certificate

A CA can have a healthy service and a working private key, and still
fail every enrollment request — because the client never reaches the
enrollment interface, or because the CA's published CDP/AIA URLs don't
actually resolve. Both failures look the same to the user ("enrollment
broken") but have completely different fixes. This lab teaches you to
distinguish them with two specific `certutil` invocations: `-ping`
proves the interface is reachable, and `-verify -urlfetch` against the
CA's own exchange certificate proves the published URLs work.

This is the second slice of the gradenegger.eu functional-test
workflow:
[Performing a functional test for a certification body](https://www.gradenegger.eu/en/performing-a-functional-test-for-a-certification-body).
Specifically it covers article sections §4 ("Testing the connection to
the enrollment interface") and §5 ("Generate and verify certification
authority exchange certificate"). You'll run the ping check from both
an admin (`manage1`) and a low-priv context (`client1` as a regular
domain user) to expose ACL-based failures, then exercise the
`certutil -cainfo xchg` workflow — the cheapest end-to-end test you
can run, because the exchange cert is auto-generated and
self-serving.

> **Before you start**: bring up `dc1`, `rootca`, `web1`, `issueca`,
> `manage1`, and `client1`. Steps 1, 2, and 4–8 run from `manage1`;
> Step 3 runs from `client1` as a regular domain user (no admin rights).
> `client1` is only defined by the `full` profile, so build with that.
>
> ```bash
> VAGRANT_DOTFILE_PATH=.vagrant-full LAB_PROFILE=full vagrant up dc1 rootca web1 issueca manage1 client1
> ```

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `issueca` RPC reachable (TCP/135 + dynamic ports) | `certutil -ping` uses DCOM/RPC |
| `issueca` HTTP reachable for CDP/AIA URLs (TCP/80) | `-verify -urlfetch` walks every published URL |
| `dc1` LDAP reachable (TCP/389) | CDP/AIA LDAP URLs resolve against AD |
| A non-admin domain user (e.g. `yourlab\testuser`) on `client1` | Step 3 ping must be unprivileged to verify enrollment ACL |
| `certutil` available on `manage1` and `client1` | shipped with Windows |
| `WebServer` template published — the exchange cert is its own template, not WebServer, so this is not actually required for Lab 2 but is required for Lab 3 (you can leave it as a follow-on) | informational |

## Setup (one-time, idempotent)

From your lab host:

<!-- @verify host=lab step=host-connectivity-precheck expect=/running/ expect=/succeeded/ rc=0 -->
```bash
vagrant status dc1 issueca manage1 client1 | grep -E '^(dc1|issueca|manage1|client1) '
# Expected: all four show "running"

# RPC reach
nc -zv 192.168.56.21 135 < /dev/null
# Expected: succeeded

# HTTP reach (the CDP/AIA HTTP endpoints)
nc -zv 192.168.56.21 80 < /dev/null
# Expected: succeeded — IIS on issueca serves /CertEnroll/

# LDAP reach to dc1 (the CDP/AIA LDAP endpoints)
nc -zv 192.168.56.10 389 < /dev/null
# Expected: succeeded
```

RDP into `manage1` (192.168.56.101) with `yourlab\Administrator`. Open
an elevated PowerShell prompt — Steps 1, 2, and 4–8 run from there.
Step 3 will switch to `client1`.

## Step 0 — Pre-flight

On `manage1`:

```powershell
# (1) Resolve the CA's config string interactively the first time
certutil -config - -ping
# A "Select Certification Authority" dialog opens. Pick the issuing CA
# and read the exact config string. Capture it:

$CA = "ISSUECA.yourlab.local\YOURLAB-Issuing-CA"

# (2) Confirm the test directory exists for output artifacts
$Work = "$env:USERPROFILE\Documents\adcs-functest"
New-Item -Path $Work -ItemType Directory -Force | Out-Null
Set-Location $Work

# (3) Confirm the testuser account exists on the domain (for Step 3)
Get-ADUser -Identity testuser -ErrorAction SilentlyContinue |
    Select-Object SamAccountName, Enabled
# Expected: SamAccountName = testuser, Enabled = True
# If absent, create with:
#   New-ADUser -SamAccountName testuser -Name 'Functest User' `
#       -AccountPassword (ConvertTo-SecureString 'Lab.Pass.1' -AsPlainText -Force) `
#       -Enabled $true -PasswordNeverExpires $true
```

## Step 1 — Ping the enrollment interface from manage1 (admin)

The first form of the enrollment-interface test answers a simple
question: does the CA's enrollment interface respond to anyone with
credentials at all? Run
the ping with an admin context. This proves DCOM/RPC reach plus the
DCOM activation ACL on the `CertSrv Request` interface.

On `manage1`:

<!-- @verify host=manage1 step=ping-admin expect=/interface is alive/ rc=0 -->
```powershell
certutil -config $CA -ping
```

Expected output, line by line:

```
Connecting to ISSUECA.yourlab.local\YOURLAB-Issuing-CA ...
Server "YOURLAB-Issuing-CA" ICertRequest2 interface is alive (XX ms)
CertUtil: -ping command completed successfully.
```

If you get `interface is alive`, the interface is reachable from this
host with this credential. Note that latency — single-digit
milliseconds is normal on a LAN; values above ~200 ms suggest DCOM
endpoint mapping issues or a slow DNS lookup. Run the ping three or
four times in quick succession to see whether the slow value is
first-call-only (DNS / DCOM endpoint cache cold) or persistent.

> **What `-ping` does NOT prove:** that *your specific user* has
> Request Certificate permission on any template. That permission is
> evaluated at submit time, not at ping time. A user who can ping can
> still fail every enrollment. Step 3 will exercise the low-priv path.

## Step 2 — Inspect the CA's pKIEnrollmentService AD object

The CA publishes its enrollment endpoint as a `pKIEnrollmentService`
object under `CN=Enrollment Services,CN=Public Key Services,CN=Services,
CN=Configuration,DC=yourlab,DC=local`. Clients discover the CA from
that object. If `-ping` worked but a client can't find the CA at all,
the object is the next thing to check.

On `manage1`:

<!-- @verify host=manage1 step=enrollment-service-object expect=/ISSUECA.yourlab.local/ rc=0 -->
```powershell
$cfgRoot = (Get-ADRootDSE).configurationNamingContext
$svc = "CN=YOURLAB-Issuing-CA,CN=Enrollment Services,CN=Public Key Services,CN=Services,$cfgRoot"

Get-ADObject -Identity $svc -Properties dNSHostName, cACertificateDN, certificateTemplates |
    Select-Object Name, dNSHostName, cACertificateDN,
        @{N='Templates'; E={ ($_.certificateTemplates -join ', ') }}
# Expected:
#   Name             : YOURLAB-Issuing-CA
#   dNSHostName      : ISSUECA.yourlab.local
#   cACertificateDN  : CN=YOURLAB-Issuing-CA, DC=yourlab, DC=local
#   Templates        : WebServer, User, Workstation, Administrator, ...
```

`dNSHostName` must resolve in DNS and `cACertificateDN` must match the
subject of the CA's signing cert. If either is wrong, clients can ping
and still fail enrollment because the discovery handshake leads them
somewhere broken.

## Step 3 — Ping from a low-priv user on client1

Now repeat the ping from a non-admin context. This is what most
real enrollment requests look like — a service account or a workstation
running autoenrollment, not an admin running ad-hoc commands.

RDP into `client1` (192.168.56.100 — adjust to your topology's IP) as
`yourlab\testuser` (password `Lab.Pass.1` from Setup), or use
runas:

```powershell
# From any session on client1, open a shell as testuser:
runas /user:yourlab\testuser /netonly cmd
```

In that low-priv shell, run:

<!-- @verify host=client1 step=ping-lowpriv expect=/interface is alive/ rc=0 -->
```powershell
certutil -config "ISSUECA.yourlab.local\YOURLAB-Issuing-CA" -ping
```

Expected output: identical to Step 1's admin ping —
`interface is alive`. The enrollment interface is callable by any
authenticated user; the gating happens later, on submit, against the
template ACL.

If this returns `0x80070005 (E_ACCESS_DENIED)` or
`0x800706BA (RPC server unavailable)`, the CA's default DCOM ACL has
been hardened beyond Microsoft defaults. Document the finding — there
are valid hardening reasons to restrict DCOM enrollment, but it breaks
unauthenticated discovery and changes how Lab 3 will behave.

## Step 4 — Generate the CA exchange certificate

The **CA Exchange certificate** is the ideal smoke-test artifact. The exchange cert is a short-lived
certificate the CA generates *of itself, for itself*, to satisfy the
"private-key archival" use case. Any authenticated user can request it
because the CA is its own template — no permissions to chase, no INF
file to write.

On `manage1`:

<!-- @verify host=manage1 step=xchg-generate expect=/completed successfully/ rc=0 -->
```powershell
certutil -config $CA -cainfo xchg "$Work\xchg.cer"
# Expected:
#   CA xchg cert[0]:
#     Subject: CN=YOURLAB-Issuing-CA-Xchg, DC=yourlab, DC=local
#     Issuer:  CN=YOURLAB-Issuing-CA, DC=yourlab, DC=local
#     NotBefore: ...
#     NotAfter:  ...   (often only days away — exchange certs are very short-lived)
#   CertUtil: -cainfo command completed successfully.
```

Verify the file landed:

```powershell
Get-Item "$Work\xchg.cer" | Select-Object Length, LastWriteTime
# Expected: Length ~ 1.2-2 KB, LastWriteTime = just now
```

`xchg.cer` is a real, validly-issued certificate from the CA's chain.
This single command exercised the *full* request-and-issue path that
all other enrollments use: RPC to enrollment interface, CSR generation,
template lookup, ACL check, signing, AIA-aware response. If `-cainfo
xchg` succeeds, the CA is issuing certificates today.

## Step 5 — Inspect the exchange certificate's extensions

The next step is to look at the resulting certificate file. The
GUI route is to double-click `xchg.cer` and click the Details tab; the
CLI route is `certutil -dump`. Use the CLI — it captures the same
information in a form you can grep.

On `manage1`:

<!-- @verify host=manage1 step=xchg-dump-inspect expect=/CAExchange/ rc=0 -->
```powershell
certutil -dump "$Work\xchg.cer" > "$Work\xchg-dump.txt"
Select-String -Path "$Work\xchg-dump.txt" -Pattern 'Subject:|Issuer:|NotAfter:|Template:|EKU|URL=|Authority Information Access|CRL Distribution|Key Usage'
```

Expected lines include:

```
Issuer:
    CN=YOURLAB-Issuing-CA, DC=yourlab, DC=local
Subject:
    CN=YOURLAB-Issuing-CA-Xchg, DC=yourlab, DC=local
NotAfter: <typically NotBefore + 7 days>
Template: CAExchange
Enhanced Key Usage
    Private Key Archival (1.3.6.1.4.1.311.21.5)
2.5.29.31: Flags = 0, Length = ...
    CRL Distribution Points
        Distribution Point Name:
            Full Name:
                URL=http://issueca.yourlab.local/CertEnroll/YOURLAB-Issuing-CA.crl
                URL=ldap:///CN=YOURLAB-Issuing-CA,CN=issueca,CN=CDP,...?certificateRevocationList?base?objectClass=cRLDistributionPoint
1.3.6.1.5.5.7.1.1: Flags = 0, Length = ...
    Authority Information Access
        [1]Authority Info Access
            Access Method=...    (1.3.6.1.5.5.7.48.2)
            Alternative Name:
                URL=http://issueca.yourlab.local/CertEnroll/issueca.yourlab.local_YOURLAB-Issuing-CA.crt
        [2]Authority Info Access
            Access Method=...    (1.3.6.1.5.5.7.48.1)
            Alternative Name:
                URL=ldap:///...?cACertificate?base?objectClass=certificationAuthority
```

Read each `URL=` line. Those are the URLs `-verify -urlfetch` will
hit in Step 6. If any of them are wrong (typo, wrong hostname, expired
share), you'll find out next.

> **What makes the exchange cert special:** Template = `CAExchange`,
> EKU = `Private Key Archival` (1.3.6.1.4.1.311.21.5), very short
> validity. It is automatically generated: the CA renews it on
> demand without operator action — every
> `-cainfo xchg` call returns a current one.

## Step 6 — Full chain + URL fetch verification

`certutil -verify -urlfetch` is the most thorough single-command
validation in the ADCS operator's toolkit. It builds the cert's chain
(using `xchg.cer` and walking AIA up to the root), fetches every CDP
URL (HTTP and LDAP), checks each CRL's signature and freshness, and
reports the entire path in one transcript. It bypasses the local URL
cache, so the result reflects current network reality, not yesterday's.

On `manage1`:

<!-- @verify host=manage1 step=xchg-verify-chain expect=/Cert is a CA/ expect=/HTTPStatus: 200/ rc=0 -->
```powershell
certutil -verify -urlfetch "$Work\xchg.cer" > "$Work\xchg-verify.txt" 2>&1
# Read the result; the file is ~80-200 lines for a 2-tier hierarchy.

Get-Content "$Work\xchg-verify.txt" | Select-String -Pattern 'Verified|Failed|URL|Issuer:|Subject:|HTTPStatus|Time:|Refresh|Cert is'
```

Key lines to find:

- `Issuer: CN=YOURLAB-Issuing-CA, ...` — chain step from exchange cert to issuing CA.
- `Issuer: CN=YOURLAB-Root-CA, ...` — chain step from issuing CA to root.
- `Cert is a CA` — appears for each intermediate.
- `URL = http://issueca.yourlab.local/CertEnroll/...` then later
  `HTTPStatus: 200` — HTTP CDP fetch succeeded.
- `URL = ldap:///CN=...` then `Result: 0` — LDAP CDP fetch succeeded.
- Final line: `Verified Issuance Policies: None` and
  `Verified Application Policies: All` and
  `CertUtil: -verify command completed successfully.`

If anything in the chain fails, the line will read `Failed` and carry
a Win32 / HRESULT code. The most common are:

| Code | Meaning |
|---|---|
| `0x80072EE7` | DNS lookup failed for the host in a CDP/AIA URL |
| `0x80072EFD` | TCP connect failed (host down or port blocked) |
| `0x80092013` | Revocation server was offline (CRL fetch timed out) |
| `0x800B010A` | A certification chain could not be built — root not trusted |

Save the working transcript. You'll compare against it after the
deliberate break in Step 7.

## Step 7 — Break a CDP URL and re-verify

To prove `-verify -urlfetch` actually catches the kind of failure you
care about, break one of the URLs. The cleanest break is "host
unreachable" — blackhole `issueca.yourlab.local` from `manage1`
temporarily with a hosts file entry.

> **Authorized lab modification only.** Step 8 restores it. Don't
> leave the hosts entry in place.

On `manage1`:

<!-- @verify host=manage1 step=break-cdp-dns expect=/10.255.255.254/ rc=0 -->
```powershell
# (1) Snapshot the hosts file (cleanup safety net)
Copy-Item C:\Windows\System32\drivers\etc\hosts "$Work\hosts.bak"

# (2) Blackhole issueca to a non-routable IP
Add-Content -Path C:\Windows\System32\drivers\etc\hosts `
    -Value "`r`n10.255.255.254  issueca.yourlab.local  # functest break"

# (3) Confirm the bad mapping wins (resolver cache might need flushing)
ipconfig /flushdns
Resolve-DnsName issueca.yourlab.local -Type A |
    Select-Object Name, IPAddress
# Expected: IPAddress = 10.255.255.254
```

Now re-run the verify and observe the failure path:

<!-- @verify host=manage1 step=cdp-break-verify expect=/0x80092013/ rc=0 -->
```powershell
certutil -verify -urlfetch "$Work\xchg.cer" > "$Work\xchg-verify-broken.txt" 2>&1
Get-Content "$Work\xchg-verify-broken.txt" |
    Select-String -Pattern 'URL = http|HTTPStatus|Time:|Failed|Error|Offline'
```

Expected new lines:

```
URL = http://issueca.yourlab.local/CertEnroll/YOURLAB-Issuing-CA.crl
  Time: ... (after ~15-30 seconds of timeout)
  Error: 0x80072EFD (... A connection with the server could not be established)
  ...
  Revocation Status: 0x80092013 (The revocation function was unable to check revocation because the revocation server was offline.)
```

That is the textbook offline-CRL failure pattern: HTTP CDP fetch times
out with `0x80072EFD`, the verifier escalates to "revocation server
offline" (`0x80092013`), and `-verify` exits non-zero. The LDAP CDP
URL still works (LDAP goes to `dc1`, not `issueca`), so the chain may
still be considered "good with caveats" depending on Windows revocation
policy.

This is the single most common production CDP-related ticket: someone
firewalled or DNS-poisoned the CRL host, autoenrollment still works
(because LDAP CDP also exists), but third-party validators that only
read HTTP CDPs (Linux clients, mobile apps, browsers on disconnected
networks) start failing chain validation across the fleet.

## Step 8 — Restore reachability and confirm green

On `manage1`:

<!-- @verify host=manage1 step=restore-dns-and-verify expect=/192.168.56.21/ expect=/completed successfully/ rc=0 -->
```powershell
# (1) Restore hosts file
Copy-Item "$Work\hosts.bak" C:\Windows\System32\drivers\etc\hosts -Force
ipconfig /flushdns

# (2) Confirm DNS now returns the real issueca IP
Resolve-DnsName issueca.yourlab.local -Type A |
    Select-Object Name, IPAddress
# Expected: IPAddress = 192.168.56.21 (or whatever your real issueca IP is)

# (3) Re-run -verify -urlfetch one more time
certutil -verify -urlfetch "$Work\xchg.cer" |
    Select-String -Pattern 'completed successfully|Failed|Error'
# Expected:
#   CertUtil: -verify command completed successfully.
```

If you see `completed successfully` with no `Failed` or `Error` lines,
the CA's enrollment interface is reachable and every URL it publishes
resolves correctly. That is the connectivity-and-exchange-certificate
gate of the functional-test workflow.

Cleanup the working artifacts:

```powershell
Remove-Item "$Work\xchg.cer", "$Work\xchg-dump.txt",
    "$Work\xchg-verify.txt", "$Work\xchg-verify-broken.txt",
    "$Work\hosts.bak" -ErrorAction SilentlyContinue
```

## What you've seen

- `certutil -config $CA -ping` is a one-shot reachability probe for
  the CA's `ICertRequest2` interface. It proves DCOM/RPC reach and
  enrollment-interface ACL — nothing more. Latency >200 ms on a LAN
  is a warning sign.
- The `pKIEnrollmentService` AD object under
  `CN=Enrollment Services,CN=Public Key Services,...` is how clients
  *find* the CA. `dNSHostName` and `cACertificateDN` must match
  reality; if they don't, ping works but enrollment still fails for
  any client doing AD-based discovery.
- The ping must also work for low-priv users — `runas` (or RDP as a
  non-admin) is how you exercise that path. A successful low-priv
  ping doesn't prove enrollment will succeed; it proves the
  *discovery* path isn't ACL-blocked.
- `certutil -cainfo xchg` generates the **CA Exchange certificate**
  (Template = `CAExchange`, EKU = `Private Key Archival`,
  1.3.6.1.4.1.311.21.5, validity in days). Because the exchange cert
  is auto-generated and self-serving, it's the cheapest "did this CA
  actually issue something just now" test.
- `certutil -verify -urlfetch` walks the chain, fetches every CDP
  and AIA URL, validates each CRL, and reports `completed
  successfully` only when every URL works. It bypasses the local URL
  cache, so the result is current.
- Common failure HRESULTs to memorise: `0x80072EE7` (DNS),
  `0x80072EFD` (TCP), `0x80092013` (revocation server offline),
  `0x800B010A` (chain not trusted). A blackholed hostname in the
  CDP URL produces the textbook 0x80072EFD → 0x80092013 escalation
  path.

With ping + xchg verify both green, the CA's interface is healthy and
its published URLs work. Lab 3 takes the next step — submit an actual
request from a non-CA template and inspect the issued certificate's
extensions end-to-end.
