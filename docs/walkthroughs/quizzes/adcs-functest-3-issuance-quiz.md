# Quiz — ADCS Functest Lab 3: End-to-End Issuance with certreq

**Lab:** `adcs-functest-issuance-walkthrough.md`
**Format:** 10 questions on `certreq` INF anatomy, the submit
workflow, certificate inspection, and CA database disposition codes.
**Suggested time:** 10–15 minutes.

---

**Q1.** Which `certreq` INF section names the certificate template
the request should be issued from?

a) `[NewRequest]`
b) `[Extensions]`
c) `[RequestAttributes]`
d) `[Strings]`

---

**Q2.** A minimal INF lists `KeyUsage = 0xA0`. Which two key usages
does that bitmask request?

(short answer; bit values welcome)

---

**Q3.** Which INF directive ensures the private key is generated in
the **user** profile rather than the local machine store?

a) `MachineKeySet = true`
b) `MachineKeySet = false`
c) `KeySpec = 2`
d) `ProviderType = 0`

---

**Q4.** Modern TLS validators (Chrome, iOS) ignore which legacy
certificate field for hostname matching, requiring DNS names to
appear where instead?

(short answer; OID for the replacement field is a bonus)

---

**Q5.** `certreq -submit -config $CA -attrib "CertificateTemplate:WebServer"
in.req out.cer` returns
`Certificate retrieved(Issued) Issued`. What is the `RequestId`
value good for after that point?

(short answer)

---

**Q6.** Match each `Disposition` value to its meaning:

| Code | Meaning |
|---|---|
| `9` | __________ |
| `20` | __________ |
| `21` | __________ |
| `30` | __________ |
| `31` | __________ |

(choices: Pending, Issued, Revoked, Failed, Denied)

---

**Q7.** Which `certutil` invocation lists every issued cert from a
specific subject CN in the CA database?

a) `certutil -dump`
b) `certutil -view -restrict "Disposition=20,SubjectCN=foo.example.com"`
c) `certutil -ping -SubjectCN foo.example.com`
d) `certutil -CATemplates SubjectCN=foo.example.com`

---

**Q8.** A submit returns `Disposition: Pending`. What is the
typical root cause and where is it configured?

a) Template requires CA Manager approval (the
   `CT_FLAG_PEND_ALL_REQUESTS` bit in `msPKI-Enrollment-Flag`)
b) The CA is offline
c) The CSR is malformed
d) The submit happened during CRL publication

---

**Q9.** Fill in the blanks — the SAN extension OID and the section
header that holds it in the INF:

```
[__________]
__________ = "{text}"
_continue_ = "dns=functest1.yourlab.local"
```

(OID + section name)

---

**Q10.** Production scenario: A `WebServer` cert request from
`certreq -submit` returns `Denied`. The user is a member of
`Domain Users` and the template grants `Authenticated Users` the
Read permission only. What's the missing permission, and where on
the template object is it set?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** **c)** `[RequestAttributes]`. The line is
`CertificateTemplate = <TemplateName>`. (The same template name
can also be passed at submit time via `-attrib
"CertificateTemplate:..."` — belt and suspenders.)

**Q2.** `0x80` = DigitalSignature, `0x20` = KeyEncipherment.
Combined `0xA0` is the standard WebServer pair.

**Q3.** **b)** `MachineKeySet = false`. Setting it `true` would
put the key in `LocalMachine\My` — appropriate for service
certificates but requires admin context for the request.

**Q4.** Common Name (`CN`) in Subject is ignored; DNS names must
appear in **Subject Alternative Name** (SAN). OID `2.5.29.17`.

**Q5.** `RequestId` is the CA database's internal handle to the
request. It's the lookup key for `certutil -view -restrict
"RequestID=..."`, for `certutil -revoke <serial>` (paired with
the SerialNumber), and for audit queries.

**Q6.**
- `9` → Pending
- `20` → Issued
- `21` → Revoked
- `30` → Failed
- `31` → Denied

**Q7.** **b)** `certutil -view -restrict "Disposition=20,
SubjectCN=foo.example.com"`. The `-restrict` filter combines
clauses with comma.

**Q8.** **a)** Template requires manager approval. Set via the
"Issuance Requirements" tab in the Certificate Templates MMC
(the `CT_FLAG_PEND_ALL_REQUESTS` bit in the template's
`msPKI-Enrollment-Flag` attribute). The request sits in the Pending
Requests container until a CA Manager approves it.

**Q9.** Section name `[Extensions]`. OID `2.5.29.17`. Full line:
`2.5.29.17 = "{text}"` then `_continue_` lines for each DNS entry.

**Q10.** The missing permission is **Enroll** (`Certificate-
Enrollment` extended right). The template ACL on the AD object
under `CN=Certificate Templates,CN=Public Key Services,CN=Services,
$configurationNamingContext` needs `Authenticated Users` (or a
more specific group) to have both Read **and** Enroll. Read alone
lets clients see the template exists but not request from it.

</details>
