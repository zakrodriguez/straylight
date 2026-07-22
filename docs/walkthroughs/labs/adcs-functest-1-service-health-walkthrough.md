# ADCS Functional Test Lab 1 — Service & Private Key Health

Before you trust a Certification Authority to mint a single production
certificate, you confirm three things in this order: the CA can reach
its own private key, the `CertSvc` service starts cleanly, and the
Event Log shows the healthy-startup pattern instead of the failure
pattern. Skip any of these and the CA might come up "Running" but
refuse every enrollment request — which is exactly the scenario that
makes ADCS troubleshooting expensive.

This lab is the first slice of the gradenegger.eu functional-test
workflow:
[Performing a functional test for a certification body](https://www.gradenegger.eu/en/performing-a-functional-test-for-a-certification-body).
Specifically it covers the workflow's first three stages: verifying the
connection to the private key, ensuring the start of the certification
authority service, and checking the event display of the certification
authority. You'll run these checks against Straylight's `issueca`, then
deliberately break the signing-cert binding so you can see the failure
event firsthand, then restore.

> **Before you start**: bring up `issueca`, `dc1`, and `manage1`. This lab
> runs entirely in an elevated PowerShell session on `issueca` (the CA) —
> service, key, and event-log checks are all CA-local.
>
> ```bash
> VAGRANT_DOTFILE_PATH=.vagrant-ad-cs-two-tier LAB_PROFILE=ad-cs-two-tier vagrant up dc1 issueca manage1
> ```
>
> The signing key on `issueca` lives in the Microsoft Software KSP
> (software-backed). The procedure is identical for HSM-backed keys —
> HSM-specific notes are flagged inline where the difference matters.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Elevated PowerShell on `issueca` | every check runs locally on the CA (local RPC / registry / event log) — remote DCOM/WinRM-second-hop don't traverse the shared NAT lab |
| `CertSvc` installed and currently in Running state | starting state for the lab; you'll restart it once |
| `dc1` reachable | several `certutil` calls resolve the CA's AD object during `-getreg` |
| Local admin on `issueca` | needed to read the key store, stop/start `CertSvc`, and read the event log |
| `yourlab\Administrator` credential | RDP / elevated PowerShell session on `issueca` |

## Setup (one-time, idempotent)

From your lab host:

<!-- @verify host=lab step=host-connectivity-precheck expect=/running/ rc=0 -->
```bash
vagrant status dc1 issueca manage1 | grep -E '^(dc1|issueca|manage1) '
# Expected: all three show "running"
```

This lab is entirely CA-side — it inspects the CA's own signing key, service,
and event log. In production you would drive these checks remotely via RSAT /
`certutil -config` from an admin workstation; on this shared-NAT VirtualBox lab
the remote RPC/DCOM and WinRM-second-hop paths can't traverse the shared NAT
interface, so open an elevated PowerShell session on `issueca`
(`yourlab\Administrator`) and run the checks there directly.

<!-- @verify host=issueca step=setup-ca preamble=true -->
```powershell
$CA  = "ISSUECA.yourlab.local\YOURLAB-Issuing-CA"
$reg = 'HKLM:\System\CurrentControlSet\Services\CertSvc\Configuration\YOURLAB-Issuing-CA'
```

## Step 0 — Pre-flight

On `issueca`:

```powershell
# certutil is present (RSAT tools ship with the CA role on issueca)
certutil -config $CA -ping
# Expected:
# Server "YOURLAB-Issuing-CA" ICertRequest2 interface is alive (...ms)
```

If `-ping` fails here, stop. The rest of the lab assumes the enrollment
interface is alive; if it isn't, go straight to Lab 2 (connectivity).

## Step 1 — Identify the signing-key provider

The CA's private signing key lives in a Cryptographic Service Provider
(CSP) or Key Storage Provider (KSP). The HSM case applies when the
provider is a third-party HSM driver; for software keys, the provider
is `Microsoft Software Key Storage Provider`. Either way, the
*existence* check is the same.

On `issueca`:

<!-- @verify host=issueca step=signing-key-provider expect=/Microsoft Software Key Storage Provider/ expect=/ProviderType REG_DWORD = 0/ rc=0 -->
```powershell
certutil -config $CA -getreg CA\CSP\Provider
# Expected (software KSP):
#   Provider REG_SZ = Microsoft Software Key Storage Provider
# (HSM example for contrast: "SafeNet Key Storage Provider" or
#  "Thales Luna Key Storage Provider".)

certutil -config $CA -getreg CA\CSP\ProviderType
# Expected (software KSP): ProviderType REG_DWORD = 0 (= KSP, not CAPI CSP)

certutil -config $CA -getreg CA\CSP\HashAlgorithm
# HashAlgorithm REG_DWORD: 0x800c (SHA256) if explicitly set; on a
# straylight-provisioned Server 2025 CA it commonly reads 0xffffffff (-1),
# meaning "use the provider default" (still SHA256). Either is healthy;
# 0x8004 (SHA-1) on an active CA would be a finding to escalate.
```

Read what came back. `Provider` names *which* implementation owns the
key bytes. `ProviderType = 0` means it's a KSP (CNG); a non-zero value
would indicate a legacy CAPI CSP. `HashAlgorithm = 0x800c` is the
algorithm ID for SHA-256 — the CA hashes requests with this before
signing. If you see `0x8004` (SHA-1) on an active CA, that's a finding
to escalate; it shouldn't appear on any straylight-provisioned CA.

> **Key point:** `certutil -ping` against the CA proves only that the
> CA *service* responds. It does NOT prove the CA can actually sign —
> for that, the service has to open a handle to the private key, and
> key-handle errors don't always surface in the ping path.

## Step 2 — Confirm the signing certificate has its private key

Every CA has a signing certificate in the local machine `My` store with
a private-key pointer back to the CSP/KSP from Step 1. The GUI check is
to open the cert and look for the `🔑 You have a private key that
corresponds to this certificate` line. We'll do it from the command
line — same information, scriptable.

On `issueca`, read the local machine store directly:

```powershell
# The CA's signing cert is in LocalMachine\My. Filter by the CA's
# CommonName (adjust the -like pattern for your CA).
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like '*YOURLAB-Issuing-CA*' } |
    Select-Object Thumbprint, Subject, NotAfter, HasPrivateKey
# Expected:
#   Thumbprint                                 Subject                       NotAfter             HasPrivateKey
#   ----------                                 -------                       --------             -------------
#   A1B2C3...                                  CN=YOURLAB-Issuing-CA, ...    2028-...             True
```

`HasPrivateKey = True` is the textual equivalent of the GUI's `🔑`
indicator. If it returns `False`, the cert is "orphaned" — present in
the store but with no private-key handle — and the CA will fail every
issuance even though the cert chain looks fine.

Now confirm `certutil` agrees with PowerShell:

<!-- @verify host=issueca step=signature-test expect=/Key Container/ expect=/Microsoft Software Key Storage Provider/ rc=0 -->
```powershell
certutil -store My '*YOURLAB-Issuing-CA*' |
    Select-String -Pattern 'Key Container|Provider|Encryption test|Signature test'
# Expected lines:
#   Key Container = {GUID}
#   Provider = Microsoft Software Key Storage Provider
#   Signature test passed
#   Encryption test passed   (or "not supported" for signing-only keys)
```

The `Signature test passed` line is the most important. `certutil`
opens a handle to the private key, signs a test value, verifies the
signature, and reports pass/fail. **This is the actual functional test
of the key.** If you only ever do one private-key check, do this one.

## Step 3 — Stop and restart the CA service

The CA service is `CertSvc`. Restarting it forces the service to
re-acquire the private-key handle from the KSP — which exercises the
same code path the CA uses at boot. A clean stop/start cycle is the
single best proof that the service can recover from any future
maintenance restart.

On `issueca`:

<!-- @verify host=issueca step=certsvc-status-preflight expect=/Running/ expect=/Automatic/ rc=0 -->
```powershell
Get-Service CertSvc | Select-Object Name, Status, StartType
# Expected: Status = Running, StartType = Automatic
```

Now the restart. Measure how long it takes — a healthy `CertSvc`
should reach Running in under 5 seconds on a software-KSP CA; HSM-backed
CAs can take 15–30 seconds depending on PIN/token unlock behavior.

<!-- @verify host=issueca step=certsvc-restart-cycle expect=/Running/ rc=0 -->
```powershell
$stop = Measure-Command { Stop-Service CertSvc }
$start = Measure-Command { Start-Service CertSvc }
[PSCustomObject]@{
    StopMs  = [int]$stop.TotalMilliseconds
    StartMs = [int]$start.TotalMilliseconds
    State   = (Get-Service CertSvc).Status
}
# Expected:
#   StopMs StartMs State
#   ------ ------- -----
#       ~500   ~3000 Running
```

If `StartMs` is several minutes, the service is hanging on something —
usually a KSP handshake, sometimes a CRL publish on startup. Continue
to Step 5; the Event Log will name the culprit.

## Step 4 — Build the ADCS Event Viewer filter

The GUI path is Event Viewer → Custom Views → Server Roles → Active
Directory Certificate Services. That custom view is automatic on a
server with the AD CS role *installed* (like `issueca`); the equivalent
scriptable filter via `Get-WinEvent` is what we build here, since it's
the recurring smoke-test form.

The two providers ADCS writes to are:

- `Microsoft-Windows-CertificationAuthority` — the CA service itself
  (startup, shutdown, issuance, revocation, CRL publication).
- `Microsoft-Windows-CertificateServicesClient-*` — autoenrollment +
  client-side events. Less relevant for server-side health but
  included for completeness.

On `issueca`:

```powershell
$filter = @{
    LogName      = 'Application'
    ProviderName = 'Microsoft-Windows-CertificationAuthority'
    StartTime    = (Get-Date).AddMinutes(-10)
}

Get-WinEvent -FilterHashtable $filter |
    Sort-Object TimeCreated |
    Select-Object TimeCreated, Id, LevelDisplayName,
        @{N='Msg'; E={ ($_.Message -split "`n")[0] }}
```

The events from your Step 3 restart should appear, in this order:

- **Event ID 53** — "Active Directory Certificate Services exited."
  (Shutdown.)
- **Event ID 27** — "Active Directory Certificate Services did not
  start: …" — only present on failure. Absent on healthy startups.
- **Event ID 100** — "Active Directory Certificate Services started:
  YOURLAB-Issuing-CA." (Successful startup completion.)

Healthy pattern = `53` then `100`, no `27` in between. If you see `27`,
read the message text — it carries the underlying error code
(`0x80092004` = "Cannot find object or property" → wrong signing-cert
thumbprint in registry; `0x80090010` = key access denied → KSP
permission issue; etc.).

## Step 5 — Tail the last 20 ADCS events for a health summary

For a recurring smoke test, the operator's preferred mode is "show me
the last N events with one line each." Build a one-shot:

```powershell
Get-WinEvent -ProviderName 'Microsoft-Windows-CertificationAuthority' -MaxEvents 20 |
    Sort-Object TimeCreated |
    Select-Object TimeCreated, Id, LevelDisplayName,
        @{N='Msg'; E={ ($_.Message -split "`n")[0] }} |
    Format-Table -AutoSize -Wrap
```

A healthy `issueca` shows mostly informational events:

- **ID 4886** — "Certificate Services received a certificate request …"
- **ID 4887** — "Certificate Services issued a certificate …"
- **ID 4872** — "Certificate Services published the CRL …"
- **ID 100** / **ID 53** — bracketed by every service restart.

What you do *not* want to see in a healthy view: `27` (start failure),
`74` (CRL publish failure), `78` (delta CRL publish failure), `44`
(template publish failure). These appear at `LevelDisplayName = Error`
or `Warning`. Filter for those to triage fast:

```powershell
Get-WinEvent -ProviderName 'Microsoft-Windows-CertificationAuthority' -MaxEvents 200 |
    Where-Object Level -le 3 |   # 1=Critical, 2=Error, 3=Warning
    Sort-Object TimeCreated -Descending |
    Select-Object -First 10 TimeCreated, Id, LevelDisplayName,
        @{N='Msg'; E={ ($_.Message -split "`n")[0] }} |
    Format-Table -AutoSize -Wrap
```

Save the command. It's the 30-second triage view, and the most
important habit you can build for ADCS operators.

## Step 6 — Deliberately break the signing-cert binding

Time to see a failure event firsthand. The CA's signing cert is
identified to the service by a thumbprint registry value at
`HKLM\System\CurrentControlSet\Services\CertSvc\Configuration\<CA Name>\
CACertHash`. Change a single byte and the service won't be able to
find the cert at startup.

> **Authorized lab modification only.** This step intentionally breaks
> the CA. Do not run any part of Step 6 against a production CA.
> Cleanup in Step 7 restores the original value.

> **Build note (not part of automated verification):** on hardened modern
> builds (Windows Server 2025), `CertSvc` recovers from a corrupt `CACertHash`
> by locating its signing certificate by name, so this step may leave the
> service **Running** rather than **Stopped**, with no event 27. The
> failure-injection demonstration below is therefore build-dependent and is
> **not** run by the walkverify harness; the automated checks stop at Step 5.
> On older builds it reproduces the classic event-27 / `CRYPT_E_NOT_FOUND`
> pattern as written.

Run the following in an elevated PowerShell on `issueca`:

```powershell
# (1) Read and remember the current thumbprint. On this build CACertHash is a
#     REG_MULTI_SZ holding the thumbprint as a space-separated hex string
#     (older builds store it as REG_BINARY bytes — adjust accordingly).
$orig = @((Get-ItemProperty -Path $reg -Name CACertHash).CACertHash)[0]
Write-Host "Original thumbprint bytes: $orig"

# (2) Flip the first byte to 00 — a definitely-wrong thumbprint
$broken = '00' + $orig.Substring(2)
Set-ItemProperty -Path $reg -Name CACertHash -Value @($broken) -Type MultiString

# (3) Try to start the service — expect a 27 event with 0x80092004
Restart-Service CertSvc -ErrorAction SilentlyContinue
Get-Service CertSvc | Select-Object Status, Name
# Expected: Status = Stopped (service refused to start)
```

If the break took effect (older builds), pull the failure event on `issueca`:

```powershell
Get-WinEvent -ProviderName 'Microsoft-Windows-CertificationAuthority' -MaxEvents 5 |
    Where-Object Id -eq 27 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List
# Expected message snippet:
#   Active Directory Certificate Services did not start: Could not load
#   or verify the current CA certificate. YOURLAB-Issuing-CA  Cannot
#   find object or property. 0x80092004 (-2146885628 CRYPT_E_NOT_FOUND)
```

That is the textbook failure pattern: event 27, error
`0x80092004 CRYPT_E_NOT_FOUND`. You'd see the same thing in production
if a cert renewal partially completed and left the registry pointing at
a cert that no longer exists in the store.

## Step 7 — Restore the signing-cert binding and confirm green

On `issueca`, write the captured `$OrigThumbprint` back to `CACertHash` (as the
`REG_MULTI_SZ` value it is on this build) and start the service. Use the
captured value, not a re-read of `$orig` from session state, since the harness
runs each annotated step independently (`$OrigThumbprint` here is the value you
recorded in Step 6):

```powershell
Set-ItemProperty -Path $reg -Name CACertHash -Value @(($OrigThumbprint).Trim()) -Type MultiString
Start-Service CertSvc
Get-Service CertSvc | Select-Object Status, Name
# Expected: Status = Running
```

On `issueca`:

```powershell
# (1) Final service state
Get-Service CertSvc | Select-Object Status
# Expected: Running

# (2) Final event check — should show one more 100 right after the 27
Get-WinEvent -ProviderName 'Microsoft-Windows-CertificationAuthority' -MaxEvents 5 |
    Sort-Object TimeCreated |
    Select-Object TimeCreated, Id, LevelDisplayName,
        @{N='Msg'; E={ ($_.Message -split "`n")[0] }} |
    Format-Table -AutoSize -Wrap
# Expected tail:
#   ... 27  Error        Active Directory Certificate Services did not start...
#   ... 100 Information  Active Directory Certificate Services started: YOURLAB-Issuing-CA.

# (3) Repeat the signature test to confirm the key path still works
certutil -store My '*YOURLAB-Issuing-CA*' | Select-String -Pattern 'Signature test passed'
# Expected: Signature test passed
```

If all three return the expected output, `issueca` is back to the
healthy baseline. Move on to Lab 2 to verify the enrollment interface
is reachable from clients, or stop here — for the "is CertSvc healthy"
question, the work is done.

## What you've seen

- The CA's signing key lives behind a CSP/KSP whose name and
  algorithm are stored in registry under
  `CA\CSP\Provider` / `CA\CSP\HashAlgorithm`. `certutil -getreg`
  reads them on the CA.
- `certutil -store My` runs an end-to-end `Signature test` — the
  authoritative answer to "can this CA actually sign right now."
  `HasPrivateKey = True` is a softer signal that says the handle
  exists; `Signature test passed` says the handle works.
- The healthy startup pattern in the ADCS Event Log is event `53`
  (shutdown) immediately followed by event `100` (start complete) on
  every restart. Any event `27` in that window is a failure to
  investigate; the message text carries the diagnostic error code
  (`0x80092004`, `0x80090010`, etc.).
- The fastest triage view is "last 200 events, level ≤ Warning,
  newest 10" — that's the one-liner to memorise for recurring
  operational health checks.
- A bad `CACertHash` registry value reproduces the most common ADCS
  failure mode (`CRYPT_E_NOT_FOUND` at startup). Restoring it
  returns the service to green without touching anything else.

This triple — key + service + log — is the foundation for every later
check in the functional-test workflow. With the foundation green, you
can trust the rest of the workflow. Continue with Lab 2 to verify the
enrollment interface is reachable from clients.
