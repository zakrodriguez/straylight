# ADCS Functional-Test Labs — Design

**Date:** 2026-05-12
**Companion to:** <https://www.gradenegger.eu/en/performing-a-functional-test-for-a-certification-body>
**Predecessor pattern:** `2026-05-08-adcs-category-labs-design.md`

## Goal

Pair gradenegger.eu's "Performing a functional test for a certification
body" article with hands-on lab walkthroughs that run the same end-to-end
health check against the existing straylight ADCS topology. The URL is
linear and procedural — 10 detail sections that walk through "is the CA
actually working?" — and translates cleanly to 4 thematic labs that the
operator can run on a freshly-provisioned `issueca` or as a recurring
post-maintenance smoke test.

Established 1:1 mapping continues: the URL teaches what to check; the
lab makes the operator type the exact `certutil` invocations and inspect
the real output on a live AD-integrated CA.

## URL → lab mapping

| # | URL detail section | Lab |
|---|---|---|
| 1 | Verification of the connection to the private key | `adcs-functest-service-health-walkthrough.md` |
| 2 | Ensure the start of the certification authority service | `adcs-functest-service-health-walkthrough.md` |
| 3 | Checking the event display of the certification authority | `adcs-functest-service-health-walkthrough.md` |
| 4 | Testing the connection to the enrollment interface | `adcs-functest-connectivity-walkthrough.md` |
| 5 | Generate and verify CA exchange certificate | `adcs-functest-connectivity-walkthrough.md` |
| 6 | Publish a certificate template on the CA | **fold** — covered by `adcs-templates-walkthrough.md`; this round references it from Lab 3 Setup |
| 7 | Apply for a certificate from the CA | `adcs-functest-issuance-walkthrough.md` |
| 8 | Revoke a certificate | `adcs-functest-revocation-walkthrough.md` |
| 9 | Issue a certificate revocation list | `adcs-functest-revocation-walkthrough.md` |
| 10 | Recheck the certificate | `adcs-functest-revocation-walkthrough.md` |

Net new: 4 labs.

## Already-covered overlap (specs document overlap; labs stay self-contained)

- **Template publishing** (URL §6) — `adcs-templates-walkthrough.md` Step 5
  covers `certutil -SetCATemplates +<Name>` and the AD-vs-CA distinction
  in depth. Lab 3 inlines the minimum publish step in its own Setup
  rather than cross-linking to the templates lab.
- **CDP/AIA URL structure** — `adcs-architecture-walkthrough.md` Step 5
  shows where the URLs come from at the CA. Labs 2/3 verify those URLs
  resolve end-to-end (the functional-test angle) rather than re-explaining
  registry origin. Each lab inlines a brief recap.
- **Event Viewer custom view** — `adcs-autoenrollment-walkthrough.md`
  Step 5 reads the CA event log for issuance events; Lab 1 reads it for
  startup/health events (different filter, different angle).

## Non-goals

- **Reinstalling or rebuilding the CA.** The labs assume `issueca` is
  already up and the `ca_services` + `cert_templates` Ansible roles have
  run. Functional testing is what happens *after* installation, not how
  to install.
- **HSM-backed key testing.** straylight's `issueca` uses software KSP
  (Microsoft Software Key Storage Provider); the URL's HSM commentary is
  noted in Lab 1 prose but not exercised. The KSP/CSP existence check
  and key-handle-test pattern is identical between software and HSM
  providers, so the lab is transferable in shape.
- **Online Responder (OCSP) testing.** straylight runs `stepca1` as the
  ACME-track OCSP responder; the ADCS Online Responder role is not
  installed on `issueca`. Lab 4 quotes the URL's OCSP caching note and
  uses CRL-based revocation throughout. A future spec can pair an OCSP
  lab if/when the Online Responder role lands.
- **Web Enrollment (CAWE) interface.** Not installed on `issueca`; lab
  uses `certreq` from `manage1` instead, which the URL explicitly endorses.
- **High availability, clustering, backup/restore.** Out of scope per
  URL and per topology.
- **Standalone CA variations.** The URL is Enterprise-CA focused; so are
  the labs. Standalone differences (no template publishing, manual
  approval workflow) are not covered.

## Per-lab content map

### Lab 1 — `adcs-functest-service-health-walkthrough.md`

URL sections: §1 (private key), §2 (service start), §3 (event log).

| Step | What runs | URL anchor |
|---|---|---|
| 0 | Pre-flight: `issueca` reachable, `CertSvc` service installed | implicit |
| 1 | Identify CA's signing-key KSP via `certutil -getreg CA\CSP\Provider` | §1 |
| 2 | Open the signing cert in the local machine store; confirm "You have a private key…" indicator via `certutil -store My` | §1 |
| 3 | Stop + start `CertSvc`, watch startup time + final state via `Get-Service` | §2 |
| 4 | Build the ADCS custom view filter in Event Viewer (filter: provider names `Microsoft-Windows-CertificationAuthority` + `Microsoft-Windows-CertificateServicesClient-*`) | §3 |
| 5 | Tail the last 20 ADCS events via `Get-WinEvent` with that filter and read the success pattern (event IDs 27 startup, 100 ready) | §3 |
| 6 | Inject a deliberate misconfiguration (rename signing-cert thumbprint registry value), restart service, watch failure event, restore | §1+§2+§3 |
| 7 | Cleanup: confirm service back to Running, event log clean | — |

Length target: 400–500 lines.

### Lab 2 — `adcs-functest-connectivity-walkthrough.md`

URL sections: §4 (enrollment ping), §5 (CA exchange certificate).

| Step | What runs | URL anchor |
|---|---|---|
| 0 | Pre-flight: `manage1` reachable, `RSAT-AD-PowerShell` + `RSAT-ADCS` available | implicit |
| 1 | Discover the CA's config string: `certutil -config -` (interactive selector, then capture the string) | §4 |
| 2 | `certutil -config "ISSUECA.yourlab.local\YOURLAB-Issuing-CA" -ping` from `manage1` — expect "interface is alive" | §4 |
| 3 | Repeat ping from `client1` (low-priv user) to confirm enrollment ACL reach, not just admin reach | §4 |
| 4 | `certutil -cainfo xchg > xchg.cer` — generate the CA's exchange certificate | §5 |
| 5 | Inspect `xchg.cer` via `certutil -dump xchg.cer` — note CA Exchange EKU (`1.3.6.1.4.1.311.21.5`), short validity, AIA/CDP fields | §5 |
| 6 | `certutil -verify -urlfetch xchg.cer` — full chain + URL endpoint validation; read every line of the output | §5 |
| 7 | Deliberately break a CDP URL (firewall block or DNS poison), re-run `-verify -urlfetch`, read the failure path | §5 |
| 8 | Cleanup: restore CDP reachability, delete `xchg.cer` | — |

Length target: 400–500 lines.

### Lab 3 — `adcs-functest-issuance-walkthrough.md`

URL sections: §6 (publish template — *referenced from Setup, not re-taught*), §7 (apply for cert).

| Step | What runs | URL anchor |
|---|---|---|
| 0 | Pre-flight: confirm `WebServer` template is published on `issueca`, or publish it inline | §6 |
| 1 | Build a minimal INF on `manage1` for an offline-style request against the `WebServer` template (Subject = `CN=functest1.yourlab.local`, EKU = serverAuth) | §7 |
| 2 | `certreq -new functest.inf functest.req` — produce the CSR | §7 |
| 3 | `certreq -submit -config "..." -attrib "CertificateTemplate:WebServer" functest.req functest.cer` — submit, get the cert in one shot | §7 |
| 4 | Open `functest.cer` and `certutil -dump functest.cer` — verify Subject, SAN, EKU, CDP, AIA, key usage | §7 |
| 5 | `certutil -verify -urlfetch functest.cer` — chain + endpoint validation succeeds | §7 |
| 6 | Confirm cert appears in the CA database via `certutil -view -restrict "Disposition=20,RequesterName=YOURLAB\Administrator" -out "RequestID,SerialNumber,SubjectCN,NotBefore"` | §7 |
| 7 | Capture the `RequestID` and `SerialNumber` for Lab 4 — write them to a small `functest-cert-ids.txt` file on `manage1` as the lab handoff artifact | — |
| 8 | Cleanup-deferred: leave the cert issued so Lab 4 can revoke it | — |

Length target: 400–500 lines.

### Lab 4 — `adcs-functest-revocation-walkthrough.md`

URL sections: §8 (revoke), §9 (publish CRL), §10 (re-check).

| Step | What runs | URL anchor |
|---|---|---|
| 0 | Pre-flight: re-issue the Lab 3 cert if it isn't present (the lab is self-contained — Setup inlines the minimum issuance) | §7 (recap) |
| 1 | `certutil -revoke "<SerialNumber>" 4` — revoke with reason "Superseded" (CRL Reason Code 4) | §8 |
| 2 | Confirm DB state changed: `certutil -view -restrict "Disposition=21,SerialNumber=..." -out "..."` (21 = Revoked) | §8 |
| 3 | Force CRL publication: `certutil -CRL` on `issueca` | §9 |
| 4 | Inspect the published CRL file at `C:\Windows\System32\CertSrv\CertEnroll\*.crl` via `certutil -dump *.crl`, confirm revoked serial appears | §9 |
| 5 | Clear URL cache on `manage1`: `certutil -urlcache crl delete` then `certutil -urlcache aia delete` | §10 |
| 6 | Re-run `certutil -verify -urlfetch functest.cer` — read the "Revocation Status: Revoked" output path | §10 |
| 7 | URL caveat callout: if OCSP responder existed, server-side cache would delay this; document why CRL is the deterministic test | §10 |
| 8 | Cleanup: unrevoke is not possible; the cert is now permanently in the revoked-list for the rest of its planned validity. Delete `xchg.cer`, `functest.*`, `functest-cert-ids.txt` on `manage1` | — |

Length target: 400–500 lines.

## File layout

- `specs/2026-05-12-adcs-functest-labs-design.md` (this file)
- `labs/adcs-functest-service-health-walkthrough.md`
- `labs/adcs-functest-connectivity-walkthrough.md`
- `labs/adcs-functest-issuance-walkthrough.md`
- `labs/adcs-functest-revocation-walkthrough.md`
- `README.md` updated — new "ADCS Functional Test" subsection under Lessons
- `INDEX.md` updated

## Infrastructure changes

**None.** Every step uses tools already present on the straylight Windows
VMs (`certutil`, `certreq`, `Get-WinEvent`, `Get-Service`, built-in MMC
snap-ins). No additional Ansible role changes, no new package installs.

## Length targets

Each lab: 400–500 lines, matching the established ADCS lab cadence
(`adcs-architecture` is 355 lines, `adcs-autoenrollment` is 414).
Functest labs are
linear validation flows — they don't need the multi-branch failure
trees that ESC1 needs, so they should land at the lower end.

## Self-containment

Per the established self-containment rule, each lab is standalone:

- No markdown cross-links between the 4 labs.
- Lab 4 inlines the minimum issuance Setup so it runs without Lab 3
  having been completed in the same session.
- Lab 3 inlines the minimum template-publish Setup so it runs without
  the templates lab.
- gradenegger.eu URL references stay; those aren't cross-lab refs.

## Citation style

Each lab opens with a "Companion to" block linking the gradenegger.eu
URL and naming the article sections that the lab covers. Inline
references to specific URL sections use the section title verbatim in
quotes ("Details: Generate and verify certification authority exchange
certificate"). The article is a single-page URL with section anchors;
the labs do not link to specific anchors because the article does not
expose stable anchor IDs in its HTML.

## Open issues / risks

- **`certutil -ping` ACLs.** Step 3 of Lab 2 (low-priv ping) depends on
  the enrollment ACL on `issueca` granting authenticated users at least
  "Read" on the CA. straylight's default does this; flag in the lab so
  the operator knows what to check if ping fails as low-priv.
- **`WebServer` template publication state.** Whether `WebServer` is
  pre-published on `issueca` depends on the `cert_templates` Ansible
  role state at execution time. Lab 3 Setup checks and publishes if
  needed — operator-portable.
- **`functest1.yourlab.local` DNS.** The cert in Lab 3 names a host
  that may not exist in DNS. That's fine for the functional test (we're
  not opening a TLS listener) but worth a note in the lab so operators
  don't expect a working TLS server out of it.
- **URL cache state on `manage1`.** Other labs (or other Windows tasks)
  may leave entries in the `manage1` URL cache. Lab 4 Step 5 clears
  both CRL and AIA caches explicitly so the re-verify is a true
  cold-cache test.

## Versioning

Article author Uwe Gradenegger; URL has no visible publication date but
last-update timestamps in the article's metadata indicate active
maintenance. If the article updates and a step diverges (different
event IDs, different `certutil` flags), update the relevant lab and
add a brief note here in a revision log.

## Revision log

- 2026-05-12 — Initial spec. 4-lab module against gradenegger.eu CA
  functional-test article. 1:1 URL-section-to-step mapping; template
  publishing folded into Lab 3 Setup since `adcs-templates-walkthrough.md`
  already covers it in depth.
