# Quiz — ADCS Functest Lab 4: Revocation, CRL Publication, and Re-verification

**Lab:** `adcs-functest-revocation-walkthrough.md`
**Format:** 10 questions on `certutil -revoke`, CRL Reason Codes,
forced CRL publication, URL cache, OCSP caching caveats, and the
canonical "Revoked" verify outcome.
**Suggested time:** 10–15 minutes.

---

**Q1.** A `certutil -revoke <serial> 4` succeeded. Where is the
revocation visible immediately, and where is it **not yet** visible?

(short answer)

---

**Q2.** Match each CRL Reason Code to its standard meaning:

| Code | Meaning |
|---|---|
| `1` | __________ |
| `3` | __________ |
| `4` | __________ |
| `6` | __________ |
| `9` | __________ |

(choices: Key Compromise, Affiliation Changed, Superseded,
Certificate Hold, Privilege Withdrawn)

---

**Q3.** Why does the lab use reason **4 (Superseded)** for
functional-testing rather than reason 0 (Unspecified) or 1 (Key
Compromise)?

(short answer)

---

**Q4.** Which command forces the CA to publish a fresh CRL right
now, and where is the resulting file stored on `issueca`?

(command + filesystem path)

---

**Q5.** A `certutil -dump` of the new CRL shows `Next Update` at
`now + 26 weeks`. Where is the publication interval configured?

a) `CRLPeriod` and `CRLPeriodUnits` under
   `HKLM\System\CurrentControlSet\Services\CertSvc\Configuration\<CA>`
b) `crl.cfg` under `C:\Windows\System32\CertSrv\`
c) The cert template's "Validity Period" tab
d) AD on the `pKIEnrollmentService` object

---

**Q6.** Why does the lab clear the URL cache on the verifying
machine with `certutil -urlcache crl delete` before re-running
`-verify -urlfetch`?

a) The cache requires admin to read
b) Without it, the verifier may serve cached pre-revocation CRL
   data and falsely report the cert as valid
c) The cache locks the file the new CRL needs to write
d) `-verify -urlfetch` ignores cache anyway, so it's defensive

---

**Q7.** The successful "Revoked" outcome of `certutil -verify -urlfetch`
exits with which HRESULT?

a) `0x80092013 CRYPT_E_REVOCATION_OFFLINE`
b) `0x80092010 CRYPT_E_REVOKED`
c) `0x800B010A CERT_E_UNTRUSTEDROOT`
d) `0x00000000 ERROR_SUCCESS`

---

**Q8.** Why may **OCSP** responders not show the revocation
immediately even after forcing CRL publication?

a) OCSP responders rebuild their cache on a polling cycle from the
   CRL, so they lag the CRL by up to one polling interval
b) OCSP responders ignore CRLs
c) OCSP responders only check revocation on Tuesdays
d) The OCSP protocol predates CRLs

---

**Q9.** Fill in the blank — the unrevoke command (special reason
code) that removes a cert from the CRL after a Certificate Hold:

```
certutil -revoke <serial> _____
```

(reason code value)

---

**Q10.** Production scenario: You revoked a cert at 14:00 with
reason 1 (Key Compromise). At 14:30 a Linux server still reports
the cert as valid; a Windows server reports it as revoked. The
CA's `CRLPeriod` is 1 week. What two operational steps will close
the gap, in order?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** Immediately visible in the CA database: the request row's
`Disposition` flipped from `20` (Issued) to `21` (Revoked) and
`RevokedReason` + `RevokedWhen` are set. **Not yet visible** in
any CRL — revocation lands on the next CRL publish, scheduled or
forced.

**Q2.**
- `1` → Key Compromise
- `3` → Affiliation Changed
- `4` → Superseded
- `6` → Certificate Hold
- `9` → Privilege Withdrawn

**Q3.** Reason 4 (Superseded) is the standard non-alarm choice.
It produces an identical-shape CRL entry to the alarm reasons
(same publish/fetch flow), but doesn't trigger key-compromise
post-mortem playbooks downstream, doesn't require a key-rotation
incident response, and reads correctly in audit logs as "we
revoked this because we tested or replaced it."

**Q4.** Command: `certutil -CRL` (run on the CA itself).
Filesystem path:
`C:\Windows\System32\CertSrv\CertEnroll\<CA Name>.crl`
(plus a `<CA Name>+.crl` delta CRL if delta CRLs are enabled).

**Q5.** **a)** `CRLPeriod` (units name) and `CRLPeriodUnits`
(numeric count) under the CA's registry configuration. Defaults
are usually `Weeks` / `1`. There's a separate
`CRLDeltaPeriod` / `CRLDeltaPeriodUnits` pair for delta CRLs.

**Q6.** **b)** Without the cache clear, the verifier may serve
the pre-revocation CRL it cached during an earlier verify run —
the new CRL exists but is never fetched. Clearing forces a cold
fetch and surfaces the current revocation status.

**Q7.** **b)** `0x80092010 CRYPT_E_REVOKED`. `certutil` exits
with this code and the output reads `Revocation Status: Revoked`.
A successful verify against a non-revoked cert exits with
`0x00000000` (option d). Option a (`CRYPT_E_REVOCATION_OFFLINE`)
is the "CRL fetch failed" path, not the "cert is revoked" path.

**Q8.** **a)** OCSP responders fetch the CRL from the CA on a
polling schedule (Windows Online Responder default: every 4
hours, configurable). Revocations published to the CRL only
appear in OCSP responses after the next poll, so OCSP can lag
the CRL by up to one polling cycle. Put another way, the online
responder has a server-side cache.

**Q9.** `-1`. Full command: `certutil -revoke <serial> -1`.
Reason `-1` is the special "remove from CRL" code, only valid
for entries that were placed on Certificate Hold (reason 6).
Other reasons can't be reversed.

**Q10.** **(1)** Force CRL publication on `issueca`:
`certutil -CRL`. This writes the new CRL with the revoked serial
to `CertEnroll\` and AD's CDP object. **(2)** Clear the URL
cache on each verifying client (`certutil -urlcache crl delete`)
or wait for the cache to expire naturally (`Next Update` on the
old CRL, often hours-to-days). The Linux server is most likely
serving a cached old CRL; once it refetches via HTTP CDP, it
will pick up the revocation and align with the Windows server.

</details>
