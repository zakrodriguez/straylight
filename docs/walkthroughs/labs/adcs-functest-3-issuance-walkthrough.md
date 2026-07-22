# ADCS Functional Test Lab 3 — End-to-End Issuance with certreq

A CA that pings and produces a valid exchange certificate has cleared
the "is it alive" gate. The next gate is "can it actually issue a
*useful* certificate" — one with a real subject, a real EKU, real CDP
and AIA URLs, that a real client could install. The exchange cert is
self-serving; a `WebServer` cert from `certreq` is what a production
workload would request. This lab runs the full issuance test
end-to-end, then validates the result the same way Lab 2
validated the exchange cert.

This is the third slice of the gradenegger.eu functional-test workflow:
[Performing a functional test for a certification body](https://www.gradenegger.eu/en/performing-a-functional-test-for-a-certification-body).
It covers article section §7 ("Apply for a certificate from the
certification authority"), with §6 ("Publish a certificate template")
inlined into Setup since `adcs-templates-walkthrough.md` covers
publishing in depth. The cert this lab produces (subject =
`CN=functest1.yourlab.local`, RequestID and SerialNumber captured to
disk) is the artifact Lab 4 revokes — but Lab 4 also re-issues if
the artifact is missing, so this lab and Lab 4 each run standalone.

> **Before you start**: bring up `issueca`, `dc1`, and `manage1`. All
> lab steps run from `manage1` over RDP.
>
> ```bash
> VAGRANT_DOTFILE_PATH=.vagrant-ad-cs-two-tier LAB_PROFILE=ad-cs-two-tier vagrant up dc1 issueca manage1
> ```

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `WebServer` template exists in AD | the lab requests from it |
| `WebServer` template published on `issueca` | publishing is a separate step from existence |
| Lab user has Read + Enroll permission on `WebServer` | ACL gate that `-ping` does not exercise |
| `certreq` available on `manage1` | shipped with Windows |
| `certutil` available on `manage1` | shipped with Windows |
| `issueca` RPC reachable | enrollment uses DCOM |
| `issueca` HTTP + LDAP reachable | `-verify -urlfetch` walks CDP/AIA |

## Setup (one-time, idempotent)

From your lab host:

<!-- @verify host=lab step=host-connectivity-precheck expect=/running/ rc=0 -->
```bash
vagrant status dc1 issueca manage1 | grep -E '^(dc1|issueca|manage1) '
# Expected: all three show "running"
```

RDP into `manage1` (192.168.56.101) with `yourlab\Administrator`. Open
an elevated PowerShell prompt.

On `manage1`:

<!-- @verify host=manage1 step=setup expect=/WebServer/ preamble=true -->
```powershell
# (1) Confirm the WebServer template exists in AD
$cfgRoot = (Get-ADRootDSE).configurationNamingContext
$tmplBase = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$cfgRoot"
Get-ADObject -SearchBase $tmplBase -Filter "name -eq 'WebServer'" |
    Select-Object Name, DistinguishedName
# Expected: Name = WebServer, DN = CN=WebServer,CN=Certificate Templates,...

# (2) Confirm WebServer is published on issueca; publish if not
$CA = "ISSUECA.yourlab.local\YOURLAB-Issuing-CA"
$published = certutil -config $CA -CATemplates | Select-String -Pattern '^\s*WebServer\b'
if (-not $published) {
    Write-Host "Publishing WebServer..."
    certutil -config $CA -SetCATemplates +WebServer
    certutil -config $CA -CATemplates | Select-String -Pattern '^\s*WebServer\b'
}
# Expected after re-check: a line beginning with "WebServer"

# (3) Working directory for artifacts
$Work = "$env:USERPROFILE\Documents\adcs-functest"
New-Item -Path $Work -ItemType Directory -Force | Out-Null
Set-Location $Work
```

> **Cross-reference (no link, just context):** the publish step above
> is the bare minimum of what `adcs-templates-walkthrough.md` Step 5
> covers in depth (AD object vs CA registry, publish vs duplicate,
> permissions). This lab inlines only the publish — every other
> template operation is intentionally out of scope here.

## Step 0 — Pre-flight

On `manage1`:

<!-- @verify host=manage1 step=preflight-ping-and-acl expect=/interface is alive/ rc=0 -->
```powershell
# (1) Confirm the CA enrollment interface is alive
certutil -config $CA -ping
# Expected: ICertRequest2 interface is alive

# (2) Confirm the WebServer template's permissions allow Administrator
#     to enroll. ACL check on the AD template object:
$tmpl = "CN=WebServer,$tmplBase"
$acl = (Get-Acl "AD:$tmpl").Access |
    Where-Object {
        $_.IdentityReference -like '*Administrators*' -or
        $_.IdentityReference -like '*Domain Admins*' -or
        $_.IdentityReference -like '*Authenticated Users*'
    } |
    Select-Object IdentityReference,
        @{N='Rights'; E={ $_.ActiveDirectoryRights }}
$acl
# Expected: at least one of these identities with ExtendedRight (Enroll)
#           appears. The standard ACL grants Domain Admins + Enterprise
#           Admins Enroll on WebServer.
```

## Step 1 — Build an INF (the request template)

`certreq -new` consumes an INF file describing what kind of CSR to
build. Write the smallest viable INF that names a subject and asks
for the `WebServer` template's EKU.

On `manage1`:

<!-- @verify host=manage1 step=build-inf expect=/functest.inf/ rc=0 -->
```powershell
@'
[NewRequest]
Subject = "CN=functest1.yourlab.local,O=yourlab,C=US"
KeyLength = 2048
KeySpec = 1
KeyUsage = 0xA0     ; DigitalSignature + KeyEncipherment
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
_continue_ = "dns=functest1"

[RequestAttributes]
CertificateTemplate = WebServer
'@ | Set-Content -Path "$Work\functest.inf" -Encoding ASCII

Get-Item "$Work\functest.inf" | Select-Object Name, Length
# Expected: functest.inf, ~700 bytes
```

Lines worth understanding:

- **`Subject`** — CommonName + Org + Country. The `O=yourlab,C=US`
  pieces aren't strictly required, but including them makes the issued
  cert read like a production cert.
- **`KeyLength = 2048`** — minimum acceptable RSA key length under the
  WebServer template's default cryptography policy. Lower would be
  refused on a modern Straylight build.
- **`KeyUsage = 0xA0`** — bitmask: 0x80 = DigitalSignature, 0x20 =
  KeyEncipherment. The WebServer EKU implies both.
- **`MachineKeySet = false`** — generate the private key in the
  user's profile, not the machine store. For a functional test this
  is correct; for a real server cert you'd flip it to `true`.
- **`Exportable = true`** — the lab cleanup needs to delete the key
  cleanly; production HTTPS keys should be non-exportable.
- **`2.5.29.17`** — Subject Alternative Name extension. Modern
  validators (browsers since 2017, Chrome+iOS strict checkers)
  require the DNS name in SAN; CN-only matching is rejected.
- **`CertificateTemplate = WebServer`** under `[RequestAttributes]`
  tells the CA which template to issue from. This is the
  `-attrib "CertificateTemplate:WebServer"` shortcut you'll see in
  the `-submit` flag below; including it in the INF is the
  belt-and-suspenders version.

## Step 2 — Produce the CSR

On `manage1`:

<!-- @verify host=manage1 step=produce-csr expect=/Request Created/ rc=0 -->
```powershell
certreq -new "$Work\functest.inf" "$Work\functest.req"
# Expected:
#   CertReq: Request Created
#   Successfully created at <path>\functest.req
```

Inspect the CSR briefly to confirm it captured what the INF asked for:

<!-- @verify host=manage1 step=inspect-csr expect=/Key Length: 2048/ rc=0 -->
```powershell
certutil -dump "$Work\functest.req" |
    Select-String -Pattern 'Subject:|Public Key|Key Length|RSA|DNS Name'
# Expected:
#   Subject:
#     CN=functest1.yourlab.local, O=yourlab, C=US
#   Public Key Algorithm:
#     RSA
#     Key Length: 2048
#   DNS Name=functest1.yourlab.local
#   DNS Name=functest1
```

If `Key Length: 2048` shows up, the local private key was generated
and the CSR is signed with it. The CSR is now ready to send.

## Step 3 — Submit the CSR

`-submit` sends the CSR to the CA's enrollment interface, waits for
issuance, and writes the resulting cert to a file in one shot. This
is the inverse of `-cainfo xchg`: `xchg` is the CA's self-request;
`-submit` is a real client's request.

On `manage1`:

<!-- @verify host=manage1 step=submit-csr expect=/RequestId:/ expect=/Issued/ rc=0 -->
```powershell
# Capture the submit response so the RequestId can be parsed without
# re-submitting — a second identical submit would issue a duplicate
# cert and put two rows in the CA DB for this subject.
$resp = certreq -submit -config $CA `
    -attrib "CertificateTemplate:WebServer" `
    "$Work\functest.req" "$Work\functest.cer" 2>&1
$resp
# Expected:
#   RequestId: <integer>      (e.g. 12)
#   ...
#   Certificate retrieved(Issued) Issued
```

The `RequestId` is the CA database's internal handle to this request.
Capture it from the response above:

```powershell
$RequestId = ($resp | Select-String -Pattern 'RequestId:').Line -replace '.*?(\d+).*','$1'
```

(If you already submitted once and the cert is on disk, skip the
re-submit — the file is the cert.) If the submit returns
`Disposition: Pending`, the template requires CA Manager approval;
that's not the default for `WebServer` and indicates the template
was modified. If it returns `Denied`, the CA refused — usually an
ACL miss on the template; double-check the Step 0 ACL output.

## Step 4 — Inspect the issued certificate

Open the cert and read its extensions — specifically the CDP, AIA,
and Enhanced Key Usage extensions, because those are what determine
whether downstream clients will accept the cert.

On `manage1`:

<!-- @verify host=manage1 step=inspect-issued-cert expect=/Template: WebServer/ rc=0 -->
```powershell
certutil -dump "$Work\functest.cer" > "$Work\functest-dump.txt"
Select-String -Path "$Work\functest-dump.txt" `
    -Pattern 'Subject:|Issuer:|NotBefore:|NotAfter:|Template:|EKU|URL=|Authority Information Access|CRL Distribution|Key Usage|Serial Number:'
```

Expected lines:

```
Issuer:
    CN=YOURLAB-Issuing-CA, DC=yourlab, DC=local
Subject:
    CN=functest1.yourlab.local, O=yourlab, C=US
Serial Number: <16-byte hex>
NotBefore: <today>
NotAfter:  <today + ~2 years>     # WebServer default validity
Template: WebServer
Enhanced Key Usage
    Server Authentication (1.3.6.1.5.5.7.3.1)
Key Usage
    Digital Signature, Key Encipherment (a0)
2.5.29.31:
    CRL Distribution Points
        URL=http://pki.yourlab.local/crl/YOURLAB-Issuing-CA.crl
1.3.6.1.5.5.7.1.1:
    Authority Information Access
        URL=http://pki.yourlab.local/aia/YOURLAB-Issuing-CA.crt
```

What to verify by eye:

- `Subject` matches the INF.
- `Template` = `WebServer`.
- `EKU` = `Server Authentication` (1.3.6.1.5.5.7.3.1).
- `Key Usage` = `Digital Signature, Key Encipherment` (matches the
  `0xA0` from the INF).
- A single HTTP `URL=` (under `http://pki.yourlab.local`) in **both**
  the CDP and the AIA blocks — no LDAP URL, since `subordinate_ca`
  strips the default CDP/AIA and publishes HTTP-only.
- `Subject Alternative Name` includes `DNS Name=functest1.yourlab.local`.

Pull the SAN explicitly — `Select-String` above doesn't grab it:

<!-- @verify host=manage1 step=extract-san expect=/DNS Name=functest1.yourlab.local/ rc=0 -->
```powershell
Select-String -Path "$Work\functest-dump.txt" -Pattern 'Subject Alternative Name|DNS Name'
# Expected:
#   2.5.29.17:
#       Subject Alternative Name
#           DNS Name=functest1.yourlab.local
#           DNS Name=functest1
```

If SAN is missing or contains only `Other Name=...`, the template's
`pKIDefaultCSPs` or "Supply in Request" flag isn't honoring the INF's
SAN block. That's a template config finding, not a CA finding.

## Step 5 — Full chain + URL fetch verification

Re-run the same `certutil -verify -urlfetch` from Lab 2, but this time
against the freshly-issued `WebServer` cert instead of the exchange
cert. The chain validation pattern is identical; the cert payload is
different.

On `manage1`:

<!-- @verify host=manage1 step=verify-chain expect=/completed successfully/ rc=0 -->
```powershell
certutil -verify -urlfetch "$Work\functest.cer" > "$Work\functest-verify.txt" 2>&1
Get-Content "$Work\functest-verify.txt" |
    Select-String -Pattern 'Issuer:|Subject:|URL =|HTTPStatus|Cert is|Verified|Failed|completed successfully'
```

Expected final line:

```
CertUtil: -verify command completed successfully.
```

If the file ends with `completed successfully`, the cert is valid
end-to-end: chain builds to the root, every published CDP URL fetches,
every AIA URL fetches, no CRL says the serial is revoked. That is the
canonical "issuance works" green-light state.

If any URL fails, read Lab 2's failure-code table to map the HRESULT
to a fix and triage from there. Don't proceed to Lab 4 until this
step is green — Lab 4 *expects* `-verify -urlfetch` to baseline-pass
before the revocation, so the post-revoke "Revoked" state is the only
new finding.

## Step 6 — Confirm the cert exists in the CA database

The CA stores every request/response in its database; this proves the
cert is materialised on the CA side, not just on the requester. Query
the DB:

<!-- @verify host=manage1 step=ca-db-confirm expect=/functest1.yourlab.local/ rc=0 -->
```powershell
certutil -config $CA -view `
    -restrict "Disposition=20,SubjectCN=functest1.yourlab.local" `
    -out "RequestID,SerialNumber,SubjectCN,NotBefore,NotAfter,CertificateTemplate"
# Expected:
#   Row 1:
#     RequestID: 0x???
#     SerialNumber: "<hex>"
#     SubjectCN: "functest1.yourlab.local"
#     NotBefore: <today>
#     NotAfter:  <today + ~2 years>
#     CertificateTemplate: "WebServer"
```

`Disposition = 20` means "Issued." The other dispositions worth knowing:

- `Disposition = 9` — Pending (requires manager approval).
- `Disposition = 21` — Revoked.
- `Disposition = 30` — Failed.
- `Disposition = 31` — Denied.

You'll see `Disposition = 21` in Lab 4 after revoking the cert.

## Step 7 — Capture RequestID and SerialNumber as a handoff artifact

Lab 4 needs both values. Write them to a file in `$Work` so the next
session — possibly hours or days later — can pick them up:

<!-- @verify host=manage1 step=capture-cert-ids expect=/CN=functest1.yourlab.local/ rc=0 -->
```powershell
$row = (
    certutil -config $CA -view `
        -restrict "Disposition=20,SubjectCN=functest1.yourlab.local" `
        -out "RequestID,SerialNumber" 2>&1
) -join "`n"

$RequestId   = ($row | Select-String -Pattern 'RequestID:\s*0x([0-9A-Fa-f]+)').Matches.Groups[1].Value
$SerialHex   = ($row | Select-String -Pattern 'SerialNumber:\s*"([0-9A-Fa-f]+)"').Matches.Groups[1].Value

[PSCustomObject]@{
    RequestId    = $RequestId
    SerialNumber = $SerialHex
    Subject      = 'CN=functest1.yourlab.local'
    IssuedAt     = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content "$Work\functest-cert-ids.txt"

Get-Content "$Work\functest-cert-ids.txt"
# Expected (example):
# {
#   "RequestId":    "C",
#   "SerialNumber": "210000000C...",
#   "Subject":      "CN=functest1.yourlab.local",
#   "IssuedAt":     "2026-05-12T14:32:00.0000000-05:00"
# }
```

That file is the handoff to Lab 4. Don't delete it in this lab's
cleanup — Lab 4 reads it.

## Step 8 — Cleanup-deferred: leave the cert issued

Unlike most labs that end with a full cleanup, this lab leaves three
artifacts in place because Lab 4 (revocation) needs them:

- `$Work\functest.cer` — the issued certificate file.
- `$Work\functest-cert-ids.txt` — the RequestID and SerialNumber.
- The corresponding row in the CA database on `issueca` (disposition 20).

If you are *not* planning to run Lab 4, do this final cleanup pass:

```powershell
# Delete the local artifacts
Remove-Item "$Work\functest.cer", "$Work\functest.req",
    "$Work\functest.inf", "$Work\functest-dump.txt",
    "$Work\functest-verify.txt",
    "$Work\functest-cert-ids.txt" -ErrorAction SilentlyContinue

# Remove the private key from the user store
$certs = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -like '*functest1.yourlab.local*' }
$certs | ForEach-Object {
    $_ | Remove-Item -ErrorAction SilentlyContinue
}

# The CA database row remains until the cert expires or is purged via
# certutil -deletedrow. That's intentional — production CAs retain
# issued-cert records for audit purposes for the full validity period.
```

## What you've seen

- A minimal `certreq` INF describes Subject, key length, key usage,
  EKU-implying template, and SAN. The `[RequestAttributes]`
  `CertificateTemplate = WebServer` line is what tells the CA which
  template to issue from.
- `certreq -new` builds the local private key and the CSR; `-submit`
  hands the CSR to the CA and stores the response. A successful
  submit returns `Certificate retrieved(Issued) Issued` and a
  `RequestId`.
- The issued cert carries the template's defaults: EKU = Server
  Authentication, validity ~2 years (WebServer default), CDP/AIA
  URLs published from the CA's registry, SAN matching the INF.
  Inspection via `certutil -dump` shows every extension; CDP, AIA,
  and EKU are the critical three.
- The same `-verify -urlfetch` pattern Lab 2 used on the exchange
  cert applies unchanged to the WebServer cert. The green state is
  the line `CertUtil: -verify command completed successfully.`
- The CA database tracks every request by Disposition: 20 = Issued,
  21 = Revoked, 9 = Pending, 30 = Failed, 31 = Denied.
  `certutil -view -restrict "Disposition=20,..."` lists current
  issued certs.
- The RequestID + SerialNumber pair is the handle to a cert for any
  later operation: revocation, archival query, audit lookup.
  Capturing them to a file makes the revocation lab self-contained
  without forcing you to re-issue.

With one real cert issued, verified, and indexed, you have a known-good
artifact to revoke. Continue with Lab 4 to exercise the revocation +
CRL publication + recheck path that closes the gradenegger.eu workflow.
