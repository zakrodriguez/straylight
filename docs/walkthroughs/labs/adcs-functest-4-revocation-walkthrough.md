# ADCS Functional Test Lab 4 — Revocation, CRL Publication, and Re-verification

A CA that can issue but can't revoke is half a CA. The functional test
isn't complete until you've revoked a known certificate, published a
fresh CRL, cleared the local URL cache, and re-validated the same
certificate to confirm it now reports `Revocation Status: Revoked`.
This lab closes the gradenegger.eu functional-test workflow by
exercising that full path: revoke → publish CRL → inspect the CRL →
flush cache → re-verify.

This is the fourth slice of the workflow:
[Performing a functional test for a certification body](https://www.gradenegger.eu/en/performing-a-functional-test-for-a-certification-body).
It covers article sections §8 ("Revoke a certificate"), §9 ("Issue a
certificate revocation list"), and §10 ("Recheck the certificate").
Lab 3 produced a `WebServer` cert for `functest1.yourlab.local` and
captured its `RequestID` and `SerialNumber` to a file. This lab reads
that file and revokes that cert; if the file is absent, the Setup
section re-issues a fresh cert so the lab is self-contained.

> **Before you start**: bring up `issueca`, `dc1`, and `manage1`. This lab has
> two actors: **CA-admin** steps run on `issueca` (the CA), and **relying-party**
> steps run on `manage1` (a client). In production you would drive the CA-admin
> commands remotely via RSAT / `certutil -config` from an admin workstation; on
> this shared-NAT VirtualBox lab, DCOM to the CA cannot traverse the shared NAT
> interface, so the hands-on CA-admin commands run on the CA host directly.
>
> ```bash
> VAGRANT_DOTFILE_PATH=.vagrant-ad-cs-two-tier LAB_PROFILE=ad-cs-two-tier vagrant up dc1 issueca manage1
> ```
>
> **Fixture (for automated verification):** this lab consumes a
> `functest1.yourlab.local` WebServer cert (Lab 3's handoff). To provision one
> non-interactively, run `ansible-playbook -i inventory/ad-cs-two-tier/inventory.ini
> playbooks/functest-cert.yml` from `vagrant/ansible` — it enrolls a fresh Issued
> cert on `issueca` and stages it (with the handoff file) where the Setup step
> reads it. Re-run it before each `walkverify verify`/`check`: the lab revokes the
> cert, so every run needs a fresh one.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `issueca` reachable on RPC, HTTP, and LDAP | revoke, CRL publish, and verify all use these |
| `issueca` admin shell | revoke + CRL publish run locally on the CA (local RPC) |
| `manage1` relying-party shell + `\\issueca\C$` read access | staging the issued cert and re-verifying it over HTTP |
| `WebServer` template published on `issueca` | re-issuance fallback in Setup |
| A `functest1.yourlab.local` cert exists or can be issued | this lab's subject of revocation |
| `certutil` available on both hosts | shipped with Windows |

## Setup (one-time, idempotent)

From your lab host:

<!-- @verify host=lab step=host-connectivity-precheck expect=/running/ rc=0 -->
```bash
vagrant status dc1 issueca manage1 | grep -E '^(dc1|issueca|manage1) '
# Expected: all three show "running"
```

Open an elevated PowerShell prompt on each host as you reach its steps
(`yourlab\Administrator`).

On `issueca` (the CA) — set the CA config, a **machine-wide** work dir (so the
staged path is the same for every account), and change into it:

<!-- @verify host=issueca step=setup-ca preamble=true -->
```powershell
$CA = "ISSUECA.yourlab.local\YOURLAB-Issuing-CA"
$Work = "C:\ProgramData\adcs-functest"
New-Item -Path $Work -ItemType Directory -Force | Out-Null
Set-Location $Work
```

On `manage1` (the relying party) — a local work dir for the staged cert and
verify output:

<!-- @verify host=manage1 step=setup-client preamble=true -->
```powershell
$Work = "C:\ProgramData\adcs-functest"
New-Item -Path $Work -ItemType Directory -Force | Out-Null
Set-Location $Work
```

### Setup branch A — Lab 3's handoff file is present (on `issueca`)

If `$Work\functest-cert-ids.txt` exists (created by Lab 3), load the
RequestID and SerialNumber from it:

```powershell
if (Test-Path "$Work\functest-cert-ids.txt") {
    $ids = Get-Content "$Work\functest-cert-ids.txt" | ConvertFrom-Json
    $RequestId   = $ids.RequestId
    $SerialNumber = $ids.SerialNumber
    Write-Host "Loaded RequestID=$RequestId SerialNumber=$SerialNumber"
}
```

If the file loaded successfully, skip to **Step 0**.

### Setup branch B — re-issue from scratch (file missing, on `issueca`)

If the file isn't there, re-issue the `functest1.yourlab.local` cert
inline so the lab is self-contained. Running this on the CA itself, the
`certutil -config`/`certreq -submit` calls use local RPC. This is the
same `certreq` sequence Lab 3 uses, condensed:

```powershell
if (-not (Test-Path "$Work\functest-cert-ids.txt")) {
    # Confirm WebServer is published
    $published = certutil -config $CA -CATemplates | Select-String -Pattern '^\s*WebServer\b'
    if (-not $published) {
        certutil -config $CA -SetCATemplates +WebServer | Out-Null
    }

    # Build the INF
    @'
[NewRequest]
Subject = "CN=functest1.yourlab.local,O=yourlab,C=US"
KeyLength = 2048
KeySpec = 1
KeyUsage = 0xA0
MachineKeySet = false
HashAlgorithm = SHA256
ProviderName = "Microsoft Software Key Storage Provider"
ProviderType = 0
RequestType = PKCS10
SMIME = false
Exportable = true

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "dns=functest1.yourlab.local&"

[RequestAttributes]
CertificateTemplate = WebServer
'@ | Set-Content -Path "$Work\functest.inf" -Encoding ASCII

    certreq -new "$Work\functest.inf" "$Work\functest.req" | Out-Null
    certreq -submit -config $CA `
        -attrib "CertificateTemplate:WebServer" `
        "$Work\functest.req" "$Work\functest.cer" | Out-Null

    # Pull RequestID and SerialNumber from the CA DB
    $row = (
        certutil -config $CA -view `
            -restrict "Disposition=20,SubjectCN=functest1.yourlab.local" `
            -out "RequestID,SerialNumber" 2>&1
    ) -join "`n"

    $RequestId    = ($row | Select-String -Pattern 'RequestID:\s*0x([0-9A-Fa-f]+)').Matches.Groups[1].Value
    $SerialNumber = ($row | Select-String -Pattern 'SerialNumber:\s*"([0-9A-Fa-f]+)"').Matches.Groups[1].Value

    [PSCustomObject]@{
        RequestId    = $RequestId
        SerialNumber = $SerialNumber
        Subject      = 'CN=functest1.yourlab.local'
        IssuedAt     = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content "$Work\functest-cert-ids.txt"

    Write-Host "Re-issued: RequestID=$RequestId SerialNumber=$SerialNumber"
}
```

Either branch leaves `$Work\functest-cert-ids.txt` on disk (Branch A
because it was already there, Branch B because it just wrote it), so
re-reading it back is a deterministic way to confirm resolution
succeeded regardless of which branch ran:

<!-- @verify host=issueca step=resolve-cert-ids capture=RequestId:/RequestID=([0-9A-Fa-f]+)/ capture=SerialNumber:/SerialNumber=([0-9A-Fa-f]+)/ expect=/RequestID=/ rc=0 -->
```powershell
$ids = Get-Content "$Work\functest-cert-ids.txt" | ConvertFrom-Json
Write-Host "RequestID=$($ids.RequestId) SerialNumber=$($ids.SerialNumber)"
```

## Step 0 — Pre-flight

On `issueca` — confirm the cert is still Issued in the CA DB:

<!-- @verify host=issueca step=preflight-ca expect=/0x14 \(20\) -- Issued/ rc=0 -->
```powershell
certutil -config $CA -view `
    -restrict "RequestID=$RequestId" `
    -out "RequestID,Disposition,DispositionMessage,SerialNumber"
# Expected:
#   Request Disposition: 0x14 (20) -- Issued
#   Serial Number: "$SerialNumber"
```

If Disposition is already `0x15 (21) Revoked`, the lab has run before.
Setup branch B will mint a fresh cert with a new SerialNumber on the
next session; for this run, skip the lab.

On `manage1` — confirm the relying party has the issued cert to check. The
`functest-cert.yml` fixture stages it to `$Work\functest.cer` on this host
(it copies through the Ansible controller, since a direct
`\\ISSUECA\C$` pull from a non-interactive session hits the WinRM double-hop).
Running by hand from an interactive admin session, copy it yourself:
`Copy-Item \\ISSUECA.yourlab.local\C$\ProgramData\adcs-functest\functest.cer $Work\ -Force`.

<!-- @verify host=manage1 step=stage-cert expect=/True/ rc=0 -->
```powershell
Test-Path "$Work\functest.cer"
# Expected: True
```

On `manage1` — baseline verify: the cert must validate cleanly **before**
revoke, so the after-state is trustworthy:

<!-- @verify host=manage1 step=baseline-verify expect=/completed successfully/ rc=0 -->
```powershell
certutil -verify -urlfetch "$Work\functest.cer" |
    Select-String -Pattern 'Revocation Status:|completed successfully|Failed'
# Expected: CertUtil: -verify command completed successfully.
```

The cert is currently good and the CA database confirms it.
Proceed to revoke.

## Step 1 — Revoke the certificate

`certutil -revoke` takes a SerialNumber and a reason code. The reason
codes are the standard RFC 5280 CRL Reason values:

| Code | Name | Use it when… |
|---|---|---|
| 0 | Unspecified | default; rarely the right choice |
| 1 | Key Compromise | private key is suspected leaked |
| 2 | CA Compromise | the *issuing CA's* key is suspected leaked |
| 3 | Affiliation Changed | subject moved orgs |
| 4 | Superseded | a newer cert replaces this one |
| 5 | Cessation of Operation | the entity is shutting down |
| 6 | Certificate Hold | temporary suspension (uniquely, reversible) |
| 8 | Remove From CRL | reverses a Certificate Hold; not a true revoke |
| 9 | Privilege Withdrawn | the subject lost an entitlement |
| 10 | AA Compromise | attribute authority compromise (rare) |
| -1 | (Special) | the certutil "unrevoke" code |

For a functional test, reason 4 (Superseded) is the standard choice —
it's non-alarming, doesn't trigger key-compromise post-mortem
playbooks, and produces a CRL entry that looks identical to the alarm
paths so the test exercises the same publish/fetch flow.

On `issueca`:

<!-- @verify host=issueca step=revoke-cert expect=/completed successfully/ rc=0 -->
```powershell
certutil -config $CA -revoke $SerialNumber 4
# Expected (the -revoke command reports only success; the new Revoked
# disposition is confirmed in the next step's CA-DB view):
#   CertUtil: -revoke command completed successfully.
```

The 0x15 in the response is the new Disposition value — Revoked. The
revocation is in the CA database immediately, but **it's not yet on
any CRL** — that's a separate publish step.

## Step 2 — Confirm the DB state changed

On `issueca`:

<!-- @verify host=issueca step=confirm-revoked expect=/0x15 \(21\) -- Revoked/ expect=/Reason: Superseded/ rc=0 -->
```powershell
certutil -config $CA -view `
    -restrict "RequestID=$RequestId" `
    -out "RequestID,Disposition,DispositionMessage,RevokedReason,RevokedWhen,SerialNumber"
# Expected:
#   Request Disposition: 0x15 (21) -- Revoked
#   Request Disposition Message: "Revoked by ..."
#   Revocation Reason: 0x4 -- Reason: Superseded
#   Revocation Date: <now>
#   Serial Number: "$SerialNumber"
```

`Disposition = 21` ("Revoked"), `RevokedReason = 4` ("Superseded"),
`RevokedWhen = now`. The CA's internal record is correct. Now the CRL
has to catch up.

## Step 3 — Force CRL publication

Normally the CA publishes a new CRL on a schedule (this lab's 26-week
`CRLPeriod`) and a new delta-CRL more frequently (default 1 day
`CRLDeltaPeriod`). For a functional test you don't want to wait.
`certutil -CRL` forces an immediate publication.

This is a CA-admin operation, so it runs on `issueca`. Republishing writes a
fresh CRL to the CA's local `CertEnroll`, but relying parties fetch it from the
**CDP** (`http://pki.yourlab.local/crl/`, served by `web1`) — so the step also
distributes the fresh CRL there. A CRL isn't live for clients until it reaches
the distribution point. The explicit `net use` credentials reach `\\web1\PKI$`
without a WinRM double-hop (the same push the build's `publish_ca_artifacts`
role uses):

<!-- @verify host=issueca step=force-crl-publish expect=/completed successfully/ rc=0 -->
```powershell
certutil -CRL
# Distribute the freshly-published CRL to the CDP (web1) so relying parties see it.
net use \\web1.yourlab.local\PKI$ /user:vagrant vagrant | Out-Null
Copy-Item 'C:\Windows\System32\CertSrv\CertEnroll\*.crl' '\\web1.yourlab.local\PKI$\crl\' -Force
net use \\web1.yourlab.local\PKI$ /delete /y | Out-Null
# Expected output (truncated):
#   CertUtil: -CRL command completed successfully.
```

If your CA is configured with a delta CRL, both the full CRL and the
delta CRL are republished. Capture the file names the CA wrote (still on
`issueca`):

<!-- @verify host=issueca step=list-crl-files expect=/YOURLAB-Issuing-CA.crl/ rc=0 -->
```powershell
Get-ChildItem 'C:\Windows\System32\CertSrv\CertEnroll\*.crl' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 4 Name, Length, LastWriteTime
# Expected: 1-2 .crl files with LastWriteTime within the last minute.
# Typically:
#   YOURLAB-Issuing-CA.crl       (full / base CRL)
#   YOURLAB-Issuing-CA+.crl      (delta CRL; the + is literal)
```

## Step 4 — Inspect the published CRL and confirm the serial appears

The CRL is a signed binary file. `certutil -dump` walks it. Since the CRL
lives on the CA, dump it there.

On `issueca` — dump the freshly-written CRL, confirm the revoked serial
appears, and inspect the metadata:

<!-- @verify host=issueca step=crl-metadata-check expect=/YOURLAB-Issuing-CA/ expect=/sha256RSA/ rc=0 -->
```powershell
certutil -dump 'C:\Windows\System32\CertSrv\CertEnroll\YOURLAB-Issuing-CA.crl' > "$Work\latest-crl-dump.txt"

# The revoked SerialNumber appears in the dump
Select-String -Path "$Work\latest-crl-dump.txt" -Pattern $SerialNumber
# Expected: a line like  Serial Number: 210000000C...

Select-String -Path "$Work\latest-crl-dump.txt" `
    -Pattern 'Issuer:|CN=|This Update:|Next Update:|CRL Number:|Signature Algorithm|Algorithm ObjectId'
# Expected:
#   Issuer:
#       CN=YOURLAB-Issuing-CA, DC=yourlab, DC=local
#   This Update: <now>
#   Next Update: <now + 26 weeks>   (per lab CRLPeriod)
#   CRL Number: 0x...                (monotonic across publications)
#   Signature Algorithm:
#       Algorithm ObjectId: 1.2.840.113549.1.1.11 sha256RSA
```

`This Update` ≈ now confirms this is the CRL `certutil -CRL` just
wrote. `Next Update` ≈ now + 26 weeks is the CRL's expiry — clients
will refetch on or before that timestamp. `CRL Number` increments by
1 with each publication; you can use it as a "what generation of CRL
are clients seeing" indicator in production.

## Step 5 — Clear the URL cache on manage1

`certutil -verify -urlfetch` honors a per-user URL cache. If `manage1`
already cached the *old* (pre-revoke) CRL, it might re-use that cache
entry for several hours instead of fetching the new CRL — masking
the revocation in the verify output. This is worth calling out
explicitly: clear the cache before re-verifying.

On `manage1`:

<!-- @verify host=manage1 step=clear-url-cache expect=/completed successfully/ rc=0 -->
```powershell
# Clear CRL cache
certutil -urlcache crl delete
# Expected: a list of deleted cached CRL files, ending in
#   CertUtil: -URLCache command completed successfully.

# Clear AIA cache (cert files for chain building)
certutil -urlcache aia delete
# Expected: similar deletion list

# Optional: clear OCSP cache too. straylight doesn't run an Online
# Responder bound to issueca, but if you ever add one this is the
# command:
# certutil -urlcache ocsp delete
```

> **A key warning:** If an online responder is
> used, it has a server-side cache so that it does not reflect the
> revocation of the certificate until the previous certificate
> revocation list has expired. That is the OCSP responder's own
> cache, *server-side*, distinct from the client's URL cache cleared
> above. CRL publication doesn't immediately re-prime the OCSP
> responder; the responder picks up the new CRL on its own polling
> cycle. This is why CRL is the deterministic functional-test path:
> you control the moment of fresh data, the client cache is local,
> and there's no asynchronous responder to wait on.

## Step 6 — Re-run -verify -urlfetch and read the Revoked output

The big moment. Same command as the baseline in Step 0; new world
state.

On `manage1`:

<!-- @verify host=manage1 step=reverify-revoked expect=/CERT_TRUST_IS_REVOKED/ expect=/CRYPT_E_REVOKED/ rc=0 -->
```powershell
certutil -verify -urlfetch "$Work\functest.cer" > "$Work\functest-verify-after.txt" 2>&1
Get-Content "$Work\functest-verify-after.txt" |
    Select-String -Pattern 'REVOKED|CRYPT_E_REVOKED|URL =|HTTPStatus|completed|Failed|Error'
```

Expected differences from the baseline:

```
ChainContext.dwErrorStatus = CERT_TRUST_IS_REVOKED (0x4)
  Element.dwErrorStatus = CERT_TRUST_IS_REVOKED (0x4)
The certificate is revoked. 0x80092010 (-2146885616 CRYPT_E_REVOKED)
Leaf certificate is REVOKED (Reason=4)
```

(The exact wording varies by Windows version; older builds print
`Revocation Status: Revoked` and a `completed FAILED` line. On Server 2025 the
revocation shows as `CERT_TRUST_IS_REVOKED` / `CRYPT_E_REVOKED` as above — the
`-verify` command line itself reports `completed successfully` because it
successfully *determined* the revoked status.)

What just happened:

- `certutil` fetched the new CRL from `http://pki.yourlab.local/crl/YOURLAB-Issuing-CA.crl`.
- It found the `functest.cer` serial in the CRL.
- It reported the revocation reason: `Cert Status: 0x4 (4) Superseded`.
- The overall verification exited with HRESULT `0x80092010`
  `CRYPT_E_REVOKED` — the canonical "this cert is revoked" failure.
- The verify command's `FAILED` final line is the **expected** outcome
  for this step. A `completed successfully` here would be a finding
  to investigate (it would mean cache wasn't cleared, or the CRL was
  signed wrong, or the verifier read the wrong CRL).

For a side-by-side comparison, diff the before/after:

<!-- @verify host=manage1 step=confirm-revoked-diff expect=/CRYPT_E_REVOKED/ expect=/is REVOKED/ rc=0 -->
```powershell
# (Run after Step 0 baseline; here, just re-run)
certutil -verify -urlfetch "$Work\functest.cer" 2>&1 |
    Out-String |
    Tee-Object -FilePath "$Work\functest-verify-after.txt" |
    Select-String -Pattern 'CRYPT_E_REVOKED|REVOKED' |
    Format-List
# Expected (Server 2025 output):
#   The certificate is revoked. 0x80092010 (-2146885616 CRYPT_E_REVOKED)
#   Leaf certificate is REVOKED (Reason=4)
```

## Step 7 — Summarise the functional-test outcome

The gradenegger.eu article frames the workflow as a checklist; the
final pass is "every item is green." The full checklist, with what
"green" means for each:

| § | Item | Green state |
|---|---|---|
| 1 | Private key accessible | `Signature test passed` (Lab 1 Step 2) |
| 2 | CertSvc starts | Status = Running, event 100 in log (Lab 1 Step 5) |
| 3 | Event log clean | No event 27 in last 24h (Lab 1 Step 5) |
| 4 | Enrollment interface reachable | `interface is alive` for both admin and low-priv (Lab 2 Steps 1, 3) |
| 5 | Exchange cert generated and verified | `-cainfo xchg` produces a file; `-verify -urlfetch` says `completed successfully` (Lab 2 Steps 4–6) |
| 6 | Template published | `WebServer` appears in `-CATemplates` output (Lab 3 Setup) |
| 7 | Cert issued from a real template | `Disposition = 20`, `-verify -urlfetch` says `completed successfully` (Lab 3 Steps 3–5) |
| 8 | Cert revoked | `Disposition = 21`, `RevokedReason = 4` (this lab Step 1–2) |
| 9 | CRL published | New `.crl` on disk, `This Update = now`, serial appears in dump (this lab Steps 3–4) |
| 10 | Recheck shows Revoked | `Revocation Status: Revoked`, `CRYPT_E_REVOKED` (this lab Step 6) |

If you can produce a screenshot or log capture for each row, the CA
has passed a functional test against the documented checklist. Save the
artifacts in `$Work` as the audit trail; rotate them per your team's
evidence-retention policy.

## Step 8 — Cleanup

The revoked certificate stays in the CA database for the rest of its
planned validity (~2 years for a WebServer cert). That's correct
behavior — production CAs don't purge revoked rows because the CRL has
to keep listing the serial until expiry. Don't try to delete it.

What you *can* clean up:

On `issueca` — the CA-side scratch (`$Work = C:\ProgramData\adcs-functest`) and
the private key the requester generated in Setup branch B:

```powershell
Remove-Item "$Work\functest.cer", "$Work\functest.req",
    "$Work\functest.inf", "$Work\functest-cert-ids.txt",
    "$Work\latest-crl-dump.txt" -ErrorAction SilentlyContinue

Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -like '*functest1.yourlab.local*' } |
    ForEach-Object { $_ | Remove-Item -ErrorAction SilentlyContinue }
```

On `manage1` — the staged cert and verify output:

```powershell
Remove-Item "$Work\functest.cer", "$Work\functest-verify-after.txt" `
    -ErrorAction SilentlyContinue
Get-ChildItem $Work
# Expected: empty, or only the working directory itself
```

The CRL `manage1` cached briefly during Step 6 is gone too — Step 5
deleted it before the verify ran, and the verify only re-cached the
post-revocation CRL, which Step 8 (3) leaves alone for the next user.
Running `certutil -urlcache crl delete` again here is optional belt
and braces.

## What you've seen

- `certutil -revoke <serial> <reason>` flips a cert from Disposition
  20 to 21 in the CA database. The well-known revocation reasons
  follow RFC 5280; reason 4 (Superseded) is the standard non-alarm
  choice for functional testing.
- The revocation lives in the CA database immediately but does **not**
  appear in any CRL until publication. `certutil -CRL` forces an
  immediate publish; without it, clients wait until `Next Update` for
  the next scheduled CRL.
- The new CRL appears on `issueca` at
  `C:\Windows\System32\CertSrv\CertEnroll\<CA Name>.crl`.
  `certutil -dump` walks it; the revoked serial appears in the
  Revoked Certificates section.
- `certutil -urlcache crl delete` clears the per-user CRL cache on
  the verifying machine. Without this, `certutil -verify -urlfetch`
  may serve cached pre-revocation data and falsely report the cert
  as valid.
- A correctly-revoked cert produces a specific failure pattern from
  `certutil -verify -urlfetch`: `Revocation Status: Revoked`,
  HRESULT `0x80092010 CRYPT_E_REVOKED`, and a non-zero exit. This
  failure is the **expected** functional-test outcome at this stage;
  a `completed successfully` would be the surprise to investigate.
- OCSP responders have a server-side cache distinct from any client
  cache. CRL-based revocation is deterministic for functional
  testing because there is no asynchronous responder between the
  publish event and the verifier; OCSP-based revocation can lag the
  CRL by up to one polling cycle.
- The full 10-item checklist (private key → service → events
  → ping → exchange cert → template publish → issuance → revoke →
  CRL → recheck) is the canonical post-deployment smoke test for an
  ADCS Enterprise CA. Run it after every install, every major
  patch, and on a recurring schedule if you want early warning of
  silent drift.

You've now exercised every step of the gradenegger.eu functional-test
workflow against a live `issueca`. The CA is verified end-to-end and
the audit trail is in `$Work`. Cleanup is done.
