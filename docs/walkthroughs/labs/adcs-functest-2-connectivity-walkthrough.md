# ADCS Functional Test Lab 2 — Enrollment Interface & CA Exchange Certificate

A CA can have a healthy service and a working private key and still fail
enrollment — because a client can't reach the enrollment interface, or
because the CA's published CDP/AIA URLs don't actually resolve. Both look
identical to the user ("enrollment broken") and have completely different
fixes. This lab teaches you to tell them apart with two `certutil`
invocations: `-ping` proves the enrollment interface is alive, and
`-verify -urlfetch` against the CA's own exchange certificate proves the
published URLs work — then deliberately breaks a URL to see the failure.

This is the second slice of the gradenegger.eu functional-test workflow:
[Performing a functional test for a certification body](https://www.gradenegger.eu/en/performing-a-functional-test-for-a-certification-body),
article sections §4 ("Testing the connection to the enrollment interface")
and §5 ("Generate and verify certification authority exchange certificate").

> **Host placement (read `docs/walkthroughs/README.md` → "Host placement
> for CA labs").** Every step here runs **on `issueca` as the CA
> operator**. On this shared-NAT lab topology a *remote* `certutil -ping`
> from another domain member returns `RPC_S_SERVER_UNAVAILABLE` — every VM
> shares NAT IP `10.0.2.15`, so the CA's RPC endpoint is advertised on an
> address that resolves back to the caller, and no host-side fix corrects
> it. The enrollment-interface health is therefore proven **locally on the
> CA**. The URL-fetch verification (`-verify -urlfetch`) is a pure
> DNS-plus-HTTP operation that behaves identically from any domain member;
> running it on `issueca` exercises the exact same path a relying party
> would.

> **Before you start**: bring up the two-tier profile —
> `dc1`, `rootca`, `issueca`, `web1`, `manage1`.
>
> ```bash
> LAB_PROFILE=ad-cs-two-tier ./up.sh
> ```

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `issueca` CertSvc running (local RPC) | `certutil -ping` on the CA proves the `ICertRequest2` interface is alive |
| `web1` HTTP reachable from `issueca` (TCP/80, `pki.yourlab.local`) | `-verify -urlfetch` fetches the HTTP CDP/AIA URLs the CA publishes |
| `dc1` DNS resolving `pki.yourlab.local` and the CA hostname | every CDP/AIA URL and the CA config string resolve through AD DNS |
| `certutil` on `issueca` | shipped with Windows Server |

> **CDP/AIA are HTTP-only in this lab.** Both the CRL and AIA URLs point at
> `http://pki.yourlab.local/...` (web1) — there is no LDAP CDP. That single
> host is the entire revocation-distribution surface, which Step 7 exploits.

## Setup (one-time, idempotent)

From your lab host, confirm the VMs are up:

<!-- @verify host=lab step=host-connectivity-precheck expect=/running/ rc=0 -->
```bash
vagrant status dc1 issueca web1 | grep -E '^(dc1|issueca|web1) '
# Expected: all three show "running"
```

RDP into `issueca` with `yourlab\Administrator` and open an elevated
PowerShell prompt, or drive it over `vagrant winrm issueca`. On `issueca`,
set the CA config string and a machine-wide work directory:

<!-- @verify host=issueca step=setup-ca preamble=true -->
```powershell
$CA = "ISSUECA.yourlab.local\YOURLAB-Issuing-CA"
$Work = "C:\ProgramData\adcs-functest"
New-Item -Path $Work -ItemType Directory -Force | Out-Null
Set-Location $Work
```

## Step 1 — Ping the enrollment interface

The enrollment-interface test answers a simple question: does the CA's
`ICertRequest2` interface respond? Run the ping locally on the CA, which
proves the interface is up and the CA's private key is loadable, without
depending on the cross-machine DCOM path that this NAT topology breaks.

On `issueca`:

<!-- @verify host=issueca step=ping-interface expect=/interface is alive/ expect=/completed successfully/ rc=0 -->
```powershell
certutil -config $CA -ping
```

Expected output:

```
Connecting to ISSUECA.yourlab.local\YOURLAB-Issuing-CA ...
Server "YOURLAB-Issuing-CA" ICertRequest2 interface is alive (0ms)
CertUtil: -ping command completed successfully.
```

`interface is alive` means the enrollment interface is reachable and the
CA is servicing requests. Latency in single-digit milliseconds is normal
locally.

> **What `-ping` does NOT prove**, and what remote ping can't tell you
> here: it does not prove that *a specific user* has Request Certificate
> permission on any template — that ACL is evaluated at submit time, not
> ping time. A principal who can reach the interface can still fail every
> enrollment. And on this shared-NAT topology a remote ping from `manage1`
> or a client returns `0x800706BA (RPC server unavailable)` regardless of
> CA health — an artifact of the lab network, not a CA fault; see the
> host-placement note above.

## Step 2 — How clients discover the CA (reference)

Clients that don't have the config string hardcoded find the CA through
its `pKIEnrollmentService` object under
`CN=Enrollment Services,CN=Public Key Services,CN=Services,CN=Configuration,DC=yourlab,DC=local`.
Its `dNSHostName` must resolve and its `cACertificateDN` must match the
CA's signing-cert subject, or a client can ping the interface and still
fail AD-based discovery.

Reading that object requires directory rights the walkverify service
account does not hold, so this step is reference-only — inspect it from an
interactive admin session on `issueca` or `dc1`:

```powershell
$cfg = ([ADSI]'LDAP://RootDSE').configurationNamingContext.Value
$svc = [ADSI]("LDAP://CN=YOURLAB-Issuing-CA,CN=Enrollment Services," +
              "CN=Public Key Services,CN=Services,$cfg")
$svc.dNSHostName; $svc.cACertificateDN
# dNSHostName    -> ISSUECA.yourlab.local
# cACertificateDN -> CN=YOURLAB-Issuing-CA, DC=yourlab, DC=local
```

## Step 3 — The low-privilege path (concept)

Most real enrollment is not an admin running ad-hoc commands — it is a
workstation or service account running autoenrollment. The interface is
callable by any authenticated principal; the gate is the **template ACL**,
checked when a request is *submitted*, not when the interface is pinged. A
low-privilege caller that can reach the interface will still be refused a
template it lacks Enroll on. Lab 3 exercises that submit-time ACL directly
with a real template request; this lab stops at interface-and-URL health.

## Step 4 — Generate the CA exchange certificate

The **CA Exchange certificate** is the ideal smoke-test artifact: a
short-lived cert the CA generates *of itself, for itself* for the
private-key-archival use case. Any authenticated caller can request it —
the CA is its own template, so there is no template ACL to chase.

`certutil -cainfo xchg` writes the certificate as PEM to **stdout** — the
`InfoName [Index]` argument form means a trailing file path is parsed as an
index and rejected (`0x80070057`), so redirect stdout to the file instead:

<!-- @verify host=issueca step=xchg-generate expect=/BEGIN CERTIFICATE/ rc=0 -->
```powershell
certutil -config $CA -cainfo xchg > "$Work\xchg.cer"
Select-String -Path "$Work\xchg.cer" -Pattern 'BEGIN CERTIFICATE'
# Expected: a line -----BEGIN CERTIFICATE----- (certutil writes a
# "CA exchange cert[0]:" header before the PEM block; it reads PEM back
# natively, so the header is harmless to -dump and -verify below)
```

`xchg.cer` is a real, validly-issued certificate from the CA's chain. This
single call exercised the full request-and-issue path every enrollment
uses: RPC to the interface, CSR generation, template lookup, signing,
AIA-aware response. If it returns a certificate, the CA is issuing today.

## Step 5 — Inspect the exchange certificate's extensions

Dump the cert and read the extensions that Step 6 will act on — especially
the published CDP/AIA URLs.

On `issueca`:

<!-- @verify host=issueca step=xchg-dump expect=/CAExchange/ expect=/pki\.yourlab\.local/ rc=0 -->
```powershell
certutil -dump "$Work\xchg.cer" > "$Work\xchg-dump.txt"
Select-String -Path "$Work\xchg-dump.txt" `
    -Pattern 'Subject:|Issuer:|NotAfter|Template=|CAExchange|URL=|Private Key Archival'
```

Expected lines include:

```
Issuer: CN=YOURLAB-Issuing-CA, DC=yourlab, DC=local
Subject: CN=YOURLAB-Issuing-CA-Xchg, DC=yourlab, DC=local
NotAfter: <NotBefore + 7 days — exchange certs are very short-lived>
    CRL Distribution Points
        URL=http://pki.yourlab.local/crl/YOURLAB-Issuing-CA.crl
    Authority Information Access
        URL=http://pki.yourlab.local/aia/YOURLAB-Issuing-CA.crt
    Certificate Template Name (Certificate Type)
        CAExchange
    Template=CA Exchange(1.3.6.1.4.1.311.21.8...)
        Private Key Archival (1.3.6.1.4.1.311.21.5)
```

Both distribution URLs are HTTP to `pki.yourlab.local` (web1) — one host
serves the entire revocation and AIA surface. Note the template is
`CAExchange` and the EKU is `Private Key Archival` — the marks of an
exchange cert.

## Step 6 — Full chain + URL-fetch verification

`certutil -verify -urlfetch` is the most thorough single-command
validation in the operator's toolkit: it builds the chain from the
exchange cert up to the root, fetches every CDP URL, checks each CRL's
signature and freshness, and reports the whole path. It bypasses the
local URL cache, so the result reflects current network reality.

On `issueca`:

<!-- @verify host=issueca step=xchg-verify expect=/Leaf certificate revocation check passed/ expect=/completed successfully/ rc=0 -->
```powershell
certutil -verify -urlfetch "$Work\xchg.cer" > "$Work\xchg-verify.txt" 2>&1
Get-Content "$Work\xchg-verify.txt" |
    Select-String -Pattern 'Issuer:|Verified "Base CRL|Failed "AIA"|revocation check passed|completed successfully'
```

Key lines to find:

- `Issuer: CN=YOURLAB-Issuing-CA` then `Issuer: CN=YOURLAB-Root-CA` — the two chain hops.
- `Verified "Base CRL (..)"` — the HTTP CDP CRL fetched and its signature checked.
- `Leaf certificate revocation check passed` — revocation confirmed good.
- `CertUtil: -verify command completed successfully.` — overall pass.

> **A `Failed "AIA"` line is expected here and is benign.** The AIA
> *certificate* URL 404s (only the CRL is published under the web root),
> but the issuing and root CA certs are already in the local store, so the
> chain builds without the AIA fetch. `-verify` reports the failed fetch
> and still completes successfully — a good illustration that not every
> `Failed` line is fatal. What matters is the final disposition.

## Step 7 — Break the CDP URL and re-verify

To prove `-verify -urlfetch` catches a real distribution failure, break
the one host every URL depends on. Blackhole `pki.yourlab.local` in the
CA's own hosts file.

> **Authorized lab modification only.** Step 8 restores it. Don't leave the
> entry in place.

There is a subtlety worth seeing first: **a blackholed CDP does not
immediately break verification, because valid CRLs are cached.** With a
fresh cached CRL, `-verify` times out fetching but falls back to cache and
still passes — which is exactly why a firewalled CDP can go unnoticed in
production until caches expire. To see the actual offline failure, clear
the URL cache first so the fetch is forced:

<!-- @verify host=issueca step=cdp-break-verify expect=/0x80092013/ rc=0 -->
```powershell
# (1) Snapshot the hosts file (cleanup safety net)
Copy-Item C:\Windows\System32\drivers\etc\hosts "$Work\hosts.bak" -Force

# (2) Force a real fetch (no cache fallback) and blackhole the CDP host
certutil -urlcache CRL delete | Out-Null
Add-Content -Path C:\Windows\System32\drivers\etc\hosts `
    -Value "`r`n10.255.255.254  pki.yourlab.local  # functest break"
ipconfig /flushdns | Out-Null

# (3) Re-verify against the dead CDP
certutil -verify -urlfetch "$Work\xchg.cer" > "$Work\xchg-verify-broken.txt" 2>&1
Get-Content "$Work\xchg-verify-broken.txt" |
    Select-String -Pattern '0x80072ee2|0x80092013|revocation server'
```

Expected new lines:

```
Error retrieving URL: The operation timed out 0x80072ee2 (WinHttp: 12002 ERROR_WINHTTP_TIMEOUT)
...
The revocation function was unable to check revocation because the revocation server was offline. 0x80092013 (-2146885613 CRYPT_E_REVOCATION_OFFLINE)
```

That is the textbook offline-CRL pattern: the HTTP CDP fetch times out
(`0x80072ee2`) and the verifier reports revocation offline (`0x80092013`).

> **On Server 2025, `-verify` still exits `completed successfully` even
> here** — it *determined* the revocation status (offline) rather than
> proving the cert bad, so `-verify`'s own exit code stays 0. A relying
> application that treats "revocation offline" as fatal (strict revocation
> checking) is where this actually breaks: browsers on disconnected
> networks, Linux/mobile validators, and any hard-fail TLS stack start
> rejecting certificates fleet-wide, while Windows autoenrollment — softer
> about offline revocation — keeps working. Diagnosing which is which is
> the whole point of `-urlfetch`.

## Step 8 — Restore reachability and confirm green

On `issueca`:

<!-- @verify host=issueca step=restore-and-verify expect=/completed successfully/ rc=0 -->
```powershell
# (1) Restore the hosts file and flush
Copy-Item "$Work\hosts.bak" C:\Windows\System32\drivers\etc\hosts -Force
ipconfig /flushdns | Out-Null

# (2) Re-verify — the chain is green again
certutil -verify -urlfetch "$Work\xchg.cer" |
    Select-String -Pattern 'revocation check passed|completed successfully|Failed "Base'
# Expected: Leaf certificate revocation check passed
#           CertUtil: -verify command completed successfully.
```

Clean up the working artifacts:

```powershell
Remove-Item "$Work\xchg.cer", "$Work\xchg-dump.txt", "$Work\xchg-verify.txt",
    "$Work\xchg-verify-broken.txt", "$Work\hosts.bak" -ErrorAction SilentlyContinue
```

## What you've seen

- `certutil -config $CA -ping` proves the CA's `ICertRequest2` interface is
  alive. Run it **on the CA** here — remote DCOM ping is unavailable on the
  shared-NAT topology, an artifact of the lab, not a CA fault.
- Clients without a hardcoded config string discover the CA through its
  `pKIEnrollmentService` object; `dNSHostName` and `cACertificateDN` must
  match reality or discovery fails after a successful ping.
- Interface reachability is not enrollment permission. The template ACL is
  the gate, checked at submit time (Lab 3).
- `certutil -cainfo xchg` emits the CA Exchange certificate (Template
  `CAExchange`, EKU `Private Key Archival`) as PEM to **stdout** — redirect
  to a file; a trailing path argument is invalid. It is the cheapest "did
  this CA just issue something" test.
- `certutil -verify -urlfetch` walks the chain and fetches every CDP/AIA
  URL. A `Failed "AIA"` line can be benign (cert already in store); the
  final disposition is what counts.
- A blackholed CDP host does **not** fail verification while a valid CRL is
  cached — clear the cache to force the real failure: `0x80072ee2` fetch
  timeout escalating to `0x80092013` revocation-offline. `-verify` on
  Server 2025 still exits successfully; strict-revocation relying parties
  are where the outage actually bites.

With ping and exchange-cert verification both green, the CA's interface is
healthy and its published URLs resolve. Lab 3 submits an actual request
from a non-CA template and inspects the issued certificate end-to-end.
