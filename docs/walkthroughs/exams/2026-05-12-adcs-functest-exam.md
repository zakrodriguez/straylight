# ADCS Functional-Test Module Exam

**Covers:** the 4 labs in the ADCS Functional-Test round paired with
[gradenegger.eu — Performing a functional test for a certification body](https://www.gradenegger.eu/en/performing-a-functional-test-for-a-certification-body):

- `adcs-functest-1-service-health-walkthrough.md` (article §1–§3)
- `adcs-functest-2-connectivity-walkthrough.md` (article §4–§5)
- `adcs-functest-3-issuance-walkthrough.md` (article §7)
- `adcs-functest-4-revocation-walkthrough.md` (article §8–§10)

**Format:** 40 questions across 4 sections matching the 4 labs.
Mix of multiple-choice, short-answer, command-recall, and
scenario-based. Last section is synthesis across labs.

**Suggested time:** 60–90 minutes.

---

## Section 1 — Service & Private Key Health (10 questions)

**Q1.** Which registry value names the CSP/KSP that owns the CA's
signing key, and what is the full `certutil` invocation that reads
it remotely?

(command recall)

---

**Q2.** A CSP `ProviderType` value of `0` denotes which class of
provider?

a) Legacy CAPI CSP
b) Modern CNG / KSP
c) Hardware HSM only
d) Smart card

---

**Q3.** What does `certutil -store My '*Issuing CA*'` actually
perform when it reports `Signature test passed`?

(short answer)

---

**Q4.** Why is PowerShell's `HasPrivateKey = True` a weaker health
signal than `Signature test passed`?

(short answer)

---

**Q5.** Which sequence of ADCS event IDs represents a healthy
`CertSvc` restart?

a) `27` then `100`
b) `100` then `53`
c) `53` then `100`
d) `74` then `100`

---

**Q6.** Match each event ID to its meaning:

| Event ID | Meaning |
|---|---|
| `27` | __________ |
| `53` | __________ |
| `74` | __________ |
| `100` | __________ |

(choices: Service start failure; Service shutdown; CRL publish
failure; Service start complete)

---

**Q7.** Which two `Get-WinEvent` filters together produce a
"recent critical/error/warning ADCS events" triage view?

(command recall — provider name + Level operator)

---

**Q8.** Bonus understanding: the lab's deliberate-break step
modified which registry value to reproduce
`0x80092004 CRYPT_E_NOT_FOUND` on startup?

a) `CA\CSP\Provider`
b) `Configuration\<CA>\CACertHash`
c) `CA\DBLogDirectory`
d) `Configuration\<CA>\CAType`

---

**Q9.** Healthy `CertSvc` restart wall-clock on a software-KSP CA
typically lands at what magnitude?

a) Sub-second
b) A few seconds (under 5)
c) 30–60 seconds
d) Several minutes

---

**Q10.** A `certutil -store My` returns `HasPrivateKey = True` but
`Signature test failed` with HRESULT `0x80090010`. Which class of
failure is that?

a) Key access denied (CSP/KSP permission)
b) Cert thumbprint mismatch
c) Service stopped
d) Revoked CA cert

---

## Section 2 — Enrollment Interface & CA Exchange (10 questions)

**Q11.** A `certutil -ping` reports `ICertRequest2 interface is
alive`. What is the **only** thing that result proves?

(short answer)

---

**Q12.** Which RPC port range does `certutil -ping` rely on?

a) Static TCP/135 only
b) TCP/135 (endpoint mapper) plus dynamic high ports negotiated
   at runtime
c) TCP/389
d) TCP/443

---

**Q13.** Which two AD attributes on `pKIEnrollmentService` are
load-bearing for client CA discovery, and what does each control?

(short answer)

---

**Q14.** A low-privilege user can `certutil -ping` the CA
successfully but every `certreq -submit` returns `Denied`. Which
specific ACL is failing the submit?

a) DCOM activation ACL on `ICertRequest2`
b) The Enroll extended right on the certificate template
c) The Read right on the `pKIEnrollmentService` object
d) The `Apply Group Policy` right on a CA-targeted GPO

---

**Q15.** `certutil -cainfo xchg out.cer` generates the CA Exchange
certificate. List its template name, EKU name + OID, and the order
of magnitude of its validity period.

(short answer)

---

**Q16.** Match each HRESULT to its failure mode:

| HRESULT | Mode |
|---|---|
| `0x80072EE7` | __________ |
| `0x80072EFD` | __________ |
| `0x80092013` | __________ |
| `0x800B010A` | __________ |

(choices: DNS lookup failed; TCP connect failed; revocation server
offline; chain not trusted)

---

**Q17.** Which `certutil` flag walks the cert's chain, fetches
every CDP and AIA URL, and bypasses the local URL cache?

(command recall — exact flag combination)

---

**Q18.** A blackhole host entry maps `issueca.yourlab.local` to
`10.255.255.254` on `manage1`. After `ipconfig /flushdns`, which
HRESULT does `certutil -verify -urlfetch` return on the HTTP CDP
fetch step, and which subsequent HRESULT does the verifier
escalate to?

(short answer)

---

**Q19.** Why is the CA Exchange certificate considered "the
cheapest end-to-end test" by the gradenegger.eu article?

(short answer, ~2 sentences)

---

**Q20.** Production scenario: A Linux workload reports CRL fetch
failures for certs issued by `issueca`; a Windows workload on the
same network reports no issues. Which two CDP URL types does each
client typically consult, and where does the asymmetry come from?

(short answer)

---

## Section 3 — End-to-End Issuance (10 questions)

**Q21.** Which INF section names the template that the request
should be issued from?

a) `[NewRequest]`
b) `[RequestAttributes]`
c) `[Extensions]`
d) `[EnhancedKeyUsageExtension]`

---

**Q22.** Which two key usages does `KeyUsage = 0xA0` request?

(short answer — names of the two bits)

---

**Q23.** Which INF directive places the private key in the user
profile rather than the local machine store, and which is
appropriate for a service certificate destined for IIS?

(short answer)

---

**Q24.** Match each AD attribute / OID to what it controls in a
WebServer-style request:

| AD attribute / OID | Controls |
|---|---|
| `2.5.29.17` | __________ |
| `2.5.29.31` | __________ |
| `1.3.6.1.5.5.7.1.1` | __________ |
| `1.3.6.1.5.5.7.3.1` | __________ |

(choices: SAN; CDP; AIA; Server Authentication EKU)

---

**Q25.** A `certreq -submit` returns `Certificate
retrieved(Issued) Issued` with `RequestId: 12`. What two later
operations is `RequestId` directly useful for?

(short answer)

---

**Q26.** Match each `Disposition` code to its meaning:

| Code | Meaning |
|---|---|
| `9` | __________ |
| `20` | __________ |
| `21` | __________ |
| `30` | __________ |
| `31` | __________ |

(choices: Pending; Issued; Revoked; Failed; Denied)

---

**Q27.** Which `certutil` command lists every currently-issued
cert from the CA database that matches a subject CN filter?

a) `certutil -view`
b) `certutil -dump`
c) `certutil -view -restrict "Disposition=20,SubjectCN=..."`
d) `certutil -CATemplates`

---

**Q28.** A submit returns `Disposition: Pending`. Where on the
template is this behavior typically configured?

(short answer — the GUI tab name or the AD attribute is fine)

---

**Q29.** Why does the lab capture `RequestID` and `SerialNumber`
to a file at the end of issuance rather than re-deriving them on
demand?

(short answer)

---

**Q30.** Production scenario: A `WebServer` cert request goes
through but its issued certificate lacks the SAN extension. The
INF correctly listed `2.5.29.17 = "{text}"` with `_continue_`
lines. What is the most likely template-side cause?

(short answer)

---

## Section 4 — Revocation, CRL, and Synthesis (10 questions)

**Q31.** A `certutil -revoke <serial> 4` succeeded. Where is the
revocation visible immediately, and where is it not yet visible?

(short answer)

---

**Q32.** Match each CRL Reason Code to its meaning:

| Code | Meaning |
|---|---|
| `1` | __________ |
| `4` | __________ |
| `6` | __________ |
| `-1` | __________ |

(choices: Key Compromise; Superseded; Certificate Hold; Remove
From CRL / unrevoke)

---

**Q33.** Where on disk does `certutil -CRL` write the new CRL on
the CA server?

(filesystem path)

---

**Q34.** Where is the **CRL publication interval** configured?

a) `CRLPeriod` / `CRLPeriodUnits` in the CA registry
   (`HKLM\System\CurrentControlSet\Services\CertSvc\Configuration\<CA>`)
b) The cert template's "Validity Period" tab
c) AD's `pKIEnrollmentService` object
d) The Online Responder configuration

---

**Q35.** Why must the URL cache on the verifying machine be
cleared before re-running `certutil -verify -urlfetch` after
revocation?

(short answer)

---

**Q36.** Successful "this cert is revoked" verification exits with
which HRESULT?

a) `0x00000000`
b) `0x80092010 CRYPT_E_REVOKED`
c) `0x80092013 CRYPT_E_REVOCATION_OFFLINE`
d) `0x80092004 CRYPT_E_NOT_FOUND`

---

**Q37.** Why does the gradenegger.eu article's §10 caveat warn
that OCSP responders may not reflect revocation immediately?

(short answer)

---

**Q38.** **Synthesis.** Walk the full 10-item article checklist
from §1 to §10 in order, with one phrase per item describing the
green state. (Numbered list, ~30 words total.)

---

**Q39.** **Synthesis scenario.** A CA passes the §1–§3 checks
(key + service + log clean) but fails §4 (`certutil -ping` fails
with `0x800706BA RPC server unavailable`) on every client. Which
three causes are most likely, and which one of them is uniquely
distinguishable by also failing the §4 check from the CA server
*to itself*?

(short answer)

---

**Q40.** **Synthesis scenario.** You have run the full functest
workflow against a freshly-installed `issueca`. Every step
succeeded, every audit artifact was captured. A week later
autoenrollment stops working across the fleet. Which **single**
command from the workflow do you run first, and why?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

### Section 1

**Q1.** Registry value `CA\CSP\Provider`. Command:
`certutil -config "<CA config string>" -getreg CA\CSP\Provider`.

**Q2.** **b)** Modern CNG / KSP. Legacy CAPI CSPs have non-zero
ProviderType values.

**Q3.** It opens a handle to the private key via the configured
CSP/KSP, signs a small test value, and verifies the resulting
signature against the public key from the cert. Pass means the
key is reachable, the handle works, and the algorithm pair is
correct end-to-end.

**Q4.** `HasPrivateKey` only checks that the cert store record
holds a pointer to a key handle. The key may be unreachable, the
permissions denied, or the algorithm mismatched — none of which
the pointer check catches. `Signature test passed` exercises the
key itself.

**Q5.** **c)** `53` (shutdown) then `100` (start complete). Any
`27` between them is a failure.

**Q6.** `27` Service start failure · `53` Service shutdown ·
`74` CRL publish failure · `100` Service start complete.

**Q7.** `Get-WinEvent -ProviderName 'Microsoft-Windows-CertificationAuthority'`
plus `Where-Object Level -le 3` (Critical=1, Error=2, Warning=3).

**Q8.** **b)** `Configuration\<CA>\CACertHash` — flipping a byte
changes the thumbprint the service tries to load, producing
`0x80092004 CRYPT_E_NOT_FOUND` on startup.

**Q9.** **b)** A few seconds (under 5). HSM-backed CAs can take
15–30 seconds. Several minutes indicates a hang (KSP handshake,
CRL publish on startup, AD replication wait).

**Q10.** **a)** Key access denied. `0x80090010` is
`NTE_PERM` from the CSP/KSP layer — the cert and key handle exist
but the calling identity (CertSvc's service account, usually
LocalSystem) doesn't have the right to use the key. Common after
HSM PIN rotation, ACL change on the key file, or KSP driver
upgrade.

### Section 2

**Q11.** It proves that the CA's `ICertRequest2` interface is
reachable from the caller with the caller's current credentials.
Nothing about issuance success, template ACLs, or key health.

**Q12.** **b)** TCP/135 (RPC endpoint mapper) plus dynamic high
ports the EPM hands out at call time. Firewalls must allow the
high port range (Windows default 49152–65535) or be configured
with a static DCOM port.

**Q13.** `dNSHostName` — clients connect to this hostname; must
resolve and match the CA's actual host. `cACertificateDN` —
clients validate against this DN; must match the subject of the
CA's signing certificate. Wrong `dNSHostName` and clients can't
reach the CA; wrong `cACertificateDN` and the discovered cert
doesn't match what the CA presents.

**Q14.** **b)** The Enroll extended right on the certificate
template. The template ACL gates issuance; the DCOM ACL only
gates `-ping`-style discovery.

**Q15.** Template = `CAExchange`. EKU = Private Key Archival,
OID `1.3.6.1.4.1.311.21.5`. Validity is in days (typically 7),
not years.

**Q16.** `0x80072EE7` DNS lookup failed · `0x80072EFD` TCP
connect failed · `0x80092013` revocation server offline ·
`0x800B010A` chain not trusted.

**Q17.** `certutil -verify -urlfetch <cert-file>`. The
`-urlfetch` flag is what bypasses the cache and fetches each
CDP/AIA URL fresh.

**Q18.** First, HTTP CDP fetch fails with `0x80072EFD` (TCP
connect failed after timeout). Verifier then escalates to
`0x80092013` (revocation server offline / could not check
revocation status).

**Q19.** Because the CA Exchange cert is auto-generated by the CA
from its own `CAExchange` template, any authenticated user can
request it without ACL or INF setup, and the request exercises
the full enrollment + signing + CDP/AIA-publish path that all
other issuances use.

**Q20.** Linux validators (OpenSSL, GnuTLS, mobile mTLS clients)
typically consult only HTTP CDP URLs. Windows validators consult
HTTP **and** LDAP CDP URLs. If the HTTP CDP host is broken
(firewall, DNS, decommissioned) but the LDAP CDP on `dc1` still
works, Windows passes (it found a working URL) and Linux fails
(its only option is broken).

### Section 3

**Q21.** **b)** `[RequestAttributes]`. The line is
`CertificateTemplate = <name>`. Alternative: pass `-attrib
"CertificateTemplate:<name>"` at submit time.

**Q22.** `0x80` = DigitalSignature, `0x20` = KeyEncipherment.
Together `0xA0` is the standard WebServer pair.

**Q23.** `MachineKeySet = false` puts the key in the **user**
profile (`Cert:\CurrentUser\My`). For an IIS service cert, set
`MachineKeySet = true` so the key lands in the **machine** store
(`Cert:\LocalMachine\My`) where IIS can read it as
LocalSystem / Network Service.

**Q24.** `2.5.29.17` SAN · `2.5.29.31` CDP · `1.3.6.1.5.5.7.1.1`
AIA · `1.3.6.1.5.5.7.3.1` Server Authentication EKU.

**Q25.** RequestId is the CA database handle. It's the lookup key
for `certutil -view -restrict "RequestID=..."` (audit / state
query) and pairs with SerialNumber for `certutil -revoke`
operations.

**Q26.** `9` Pending · `20` Issued · `21` Revoked · `30` Failed ·
`31` Denied.

**Q27.** **c)** `certutil -view -restrict "Disposition=20,
SubjectCN=..."`. The combined restriction filters by both
disposition (Issued) and CN.

**Q28.** "Issuance Requirements" tab in the Certificate Templates
MMC — "CA certificate manager approval" checkbox. Underlying AD
attribute: `CT_FLAG_PEND_ALL_REQUESTS` in `msPKI-Enrollment-Flag`
on the template object. Requests sit in the Pending Requests container
until a CA Manager approves or denies.

**Q29.** Captures the lab handoff cleanly. The CA DB query is
several lines of `certutil -view -restrict` output to parse; the
file is one `ConvertFrom-Json` call. It also enables a later
session (hours or days) to pick up the handoff without re-running
the issuance step.

**Q30.** The template has "Supply in Request" *disabled* for
subject information (it's set to "Build from this Active
Directory information" instead). The INF's SAN block is silently
dropped because the template authoritatively builds Subject + SAN
from AD attributes. Fix: duplicate the template, switch Subject
Name to "Supply in Request" on the new version, publish that.

### Section 4

**Q31.** Immediately: the CA database flips the row's Disposition
from `20` to `21` and records `RevokedReason` + `RevokedWhen`.
Not yet: any CRL — revocation lands in the CRL only on the next
publish (scheduled or forced).

**Q32.** `1` Key Compromise · `4` Superseded · `6` Certificate
Hold · `-1` Remove From CRL / unrevoke (only valid following a
Certificate Hold).

**Q33.** `C:\Windows\System32\CertSrv\CertEnroll\<CA Name>.crl`
(plus `<CA Name>+.crl` for the delta CRL when enabled).

**Q34.** **a)** `CRLPeriod` / `CRLPeriodUnits` in the CA
registry. Separate `CRLDeltaPeriod` / `CRLDeltaPeriodUnits` for
delta CRLs.

**Q35.** Without clearing the per-user URL cache, the verifier
may serve the pre-revocation CRL it cached during an earlier
verify and falsely report the cert as valid. The cache hides
fresh state until its entries expire (`Next Update`) or are
explicitly deleted.

**Q36.** **b)** `0x80092010 CRYPT_E_REVOKED`. Output also reads
`Revocation Status: Revoked`. Option a is the "valid cert" path;
option c is the "couldn't fetch CRL" path; option d is the
service-startup failure path.

**Q37.** Because OCSP responders rebuild their cache on a
polling cycle from the CRL — Windows Online Responder default
4 hours, configurable. CRL publishes don't push to OCSP; OCSP
polls. So OCSP can lag the CRL by up to one polling interval
even after a successful `certutil -CRL`.

**Q38.** Numbered list:
1. Private key has a working `Signature test passed`.
2. `CertSvc` Status = Running.
3. Event Log shows `53`→`100` with no `27` since restart.
4. `certutil -ping` returns `interface is alive` for admin and low-priv.
5. `certutil -cainfo xchg` produces a cert; `-verify -urlfetch` passes.
6. Target template appears in `certutil -CATemplates`.
7. `certreq -submit` returns `Issued`; cert `-verify -urlfetch` passes.
8. `certutil -revoke <serial> 4` produces `Disposition=21` and `RevokedReason=4`.
9. `certutil -CRL` writes a new CRL with `This Update = now`; revoked serial appears.
10. After `certutil -urlcache crl delete`, `-verify -urlfetch` returns `CRYPT_E_REVOKED`.

**Q39.** Three likely causes: (a) the RPC service is hung
inside the CA host (the service registers as Running but DCOM
endpoints aren't responding); (b) the firewall on `issueca` is
blocking inbound TCP/135 + dynamic high ports; (c) network
ACLs between client subnet and CA subnet drop the RPC traffic.
**(a)** is uniquely distinguishable because the loopback
`-ping` from the CA to itself also fails — network and
firewall causes don't affect loopback. If the CA's self-ping
also fails, restart `CertSvc` and re-test.

**Q40.** Run `certutil -config $CA -ping` first. It's the
fastest, lowest-blast-radius probe of the enrollment interface
and it cleanly distinguishes "CA service broken" from "CA
service fine, but autoenrollment GPO / template / template ACL
broken." If `-ping` fails, walk Lab 1 to triage the CA service
and key; if `-ping` succeeds, the failure is downstream of the
enrollment interface and Lab 3's submit path or the template
ACL is where to look next.

</details>
