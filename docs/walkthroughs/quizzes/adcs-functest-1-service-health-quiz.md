# Quiz — ADCS Functest Lab 1: Service & Private Key Health

**Lab:** `adcs-functest-service-health-walkthrough.md`
**Format:** 10 questions on CSP/KSP identification, private-key
signature testing, CertSvc lifecycle, and the ADCS Event Log
healthy-vs-failure pattern.
**Suggested time:** 10–15 minutes.

---

**Q1.** Which registry value names the CSP/KSP that owns the CA's
signing key, and what `certutil` flag reads it?

(command recall + short answer)

---

**Q2.** Of these two CSP `ProviderType` values, which means
"modern CNG / KSP"?

a) `0`
b) `1`
c) `12`
d) `24`

---

**Q3.** A `certutil -store My '*Issuing CA*'` run completes with a
line reading `Signature test passed`. What did `certutil` actually
just do to produce that line?

(short answer, ~2 sentences)

---

**Q4.** PowerShell's `Get-ChildItem Cert:\LocalMachine\My` reports
`HasPrivateKey = True` for the CA's signing cert. Why is this a
*weaker* health signal than `Signature test passed`?

(short answer)

---

**Q5.** The healthy startup pattern in the ADCS Event Log on a
restart of `CertSvc` is which sequence of event IDs?

a) `27` then `100`
b) `53` then `27` then `100`
c) `53` then `100`
d) `100` then `53`

---

**Q6.** A failed-startup event 27 carries HRESULT `0x80092004`.
What did that error map to, and what's the typical root cause?

a) `CRYPT_E_NOT_FOUND` — wrong `CACertHash` registry value or the
   signing cert is missing from the store
b) `CRYPT_E_NO_PROVIDER` — CSP driver not installed
c) `CRYPT_E_REVOKED` — the CA's own cert is revoked on its parent
d) `CRYPT_E_BAD_KEY` — private-key file corrupted

---

**Q7.** The lab triages with this PowerShell one-liner:

```powershell
Get-WinEvent -ComputerName issueca.yourlab.local `
  -ProviderName 'Microsoft-Windows-CertificationAuthority' -MaxEvents 200 |
  Where-Object Level -le 3 | ...
```

What does `Level -le 3` filter for?

a) Information and Verbose events only
b) Critical, Error, and Warning events only
c) The last 3 events of any level
d) Audit events only

---

**Q8.** The lab's Step 6 deliberately breaks the CA by flipping a
byte in which registry path?

(path recall — value name + REG_xxx type)

---

**Q9.** Fill in the blank — the cmdlet to perform an end-to-end
sign-then-verify test against a CA's private key from the local
machine store:

```
certutil _____ My '*Issuing CA*'
```

(command recall)

---

**Q10.** Why is restarting `CertSvc` (rather than just calling
`certutil -ping`) the canonical proof that the CA can recover from
future maintenance?

(short answer, ~2 sentences)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** Registry value: `CA\CSP\Provider` (REG_SZ). Read with
`certutil -getreg CA\CSP\Provider` — works locally or with
`-config <CA>` to read a remote CA.

**Q2.** **a)** `0`. ProviderType `0` is CNG/KSP (the modern Key
Storage Provider). Non-zero values are legacy CAPI CSPs.

**Q3.** `certutil` opened a handle to the private key via the
configured CSP/KSP, signed a small test value with it, then
verified the signature with the public key from the cert. Pass
means the key is reachable, the handle works, and the algorithm
binding is correct.

**Q4.** `HasPrivateKey` only checks that the certificate store
record contains a pointer back to a CSP/KSP key handle. The key
itself could be unreachable (HSM offline, KSP misconfigured),
permissions could deny access, or the algorithm pair could
mismatch — none of which are caught by the pointer check.
`Signature test passed` actually exercises the key.

**Q5.** **c)** `53` (shutdown / "exited") then `100` (start
complete / "started: CA name"). Any `27` in the middle is a
failure path.

**Q6.** **a)** `CRYPT_E_NOT_FOUND`. Most often the
`CACertHash` registry value points at a cert thumbprint that no
longer exists in the local machine `My` store — common after a
partial cert renewal or store cleanup.

**Q7.** **b)** Critical (Level 1), Error (Level 2), and Warning
(Level 3). `-le 3` selects all three at once for fast triage.

**Q8.**
`HKLM:\System\CurrentControlSet\Services\CertSvc\Configuration\<CA Name>\CACertHash`
value name `CACertHash`, type `REG_BINARY`. The bytes are the
SHA-1 thumbprint of the CA's current signing certificate.

**Q9.** `-store` — full command: `certutil -store My '*Issuing CA*'`.
Look for `Signature test passed` in the output.

**Q10.** Restarting forces the service to re-acquire the
private-key handle from the CSP/KSP, exercising the same
boot-time code path the service will hit on every future restart.
A `-ping` only confirms the network/DCOM endpoint is up — it
doesn't re-prove the key path.

</details>
