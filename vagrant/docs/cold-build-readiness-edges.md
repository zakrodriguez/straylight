# Cold-build readiness: cross-VM dependency edge map

The spec for cold-build reliability. A **cross-VM edge** is any point where one VM's
provisioning depends on another VM's state (published cert/CRL, DC serving LDAP, a
listening service, an artifact at a distribution point, a DNS record). Cold builds
fail when an edge is crossed on a *timing assumption* instead of a *readiness
signal*; the parallel-launch / domain-join / publish races are one bug class.

## The principle

Each cross-VM edge must wait on a **real, observable upstream signal**, not a fixed
sleep, without serializing the build:

1. **Gate on an observable predicate** — a published CRL returning HTTP 200, an
   LDAP response from `nltest /dsgetdc`, a CA answering `certutil -ping`, a
   listening socket. Never a bare `Start-Sleep`.
2. **Preserve parallelism.** Gates are poll loops that run while other VMs progress.
3. **Never probe a host that is rebooting.** Domain-join reboots kill WinRM, and no
   Ansible retry primitive survives an unreachable host (`until:` does not retry it,
   `ignore_unreachable: true` skips *through* it, `block`/`rescue` does not catch
   it; only `wait_for_connection` survives, and it passes *before* the reboot).
   Instead gate on a **forward signal on a stable third host** (typically web1)
   polled with `uri`/`get_url`, which returns a normal failed result (not
   host-unreachable) and so is cleanly `until`-retryable.
4. **Where no clean signal exists, say so** — label it *best-effort + bounded retry*.

## Edge map

Grouped by gate mechanism (one mechanism covers several VMs; rows are the roles).
Verified against `main` at time of writing; cite **role + task name**, not line numbers.

| Edge class | Consumer → Producer | Signal / mechanism | Role (task) | Gate |
|---|---|---|---|---|
| **Domain join** | web1, manage1, issueca, issueca-pqc → dc1 (LDAP) | `nltest /dsgetdc:<domain>` retry (45×20s = 15 min) — LDAP-serving, not just DNS | `domain_join` (wait for DC) | clean signal |
| **Post-reboot WMI** | any Windows VM → itself after domain-join reboot | `Win32_ComputerSystem` + `Get-NetIPConfiguration` probe (60×6s) | `domain_join` | clean signal |
| **Subordinate CA → parent** | issueca → rootca, issueca-pqc → rootca-pqc | `certutil -ping` against parent RPC (75×20s = 25 min) | `subordinate_ca` | clean signal |
| **CA → CDP reachable** | issueca(/-pqc) → web1 IIS | `Invoke-WebRequest` on the CRL distribution point before CA install (30×20s) | `subordinate_ca` | clean signal |
| **CertSvc RPC ready** | rootca / issueca → local CertSvc after `Restart-Service` | `certutil -ping` (local LRPC) before `certutil -crl` — closes the classic CRL race | `standalone_ca`, `subordinate_ca` | clean signal |
| **Artifacts published** | web1 → rootca / issueca(/-pqc) SMB share | `Test-Path` on the published cert/CRL after `net use` (30×10s) | `publish_ca_artifacts` | clean signal |
| **Root CA in trust store** | web1, manage1 → issueca (GPO autoenroll) | poll `Cert:\LocalMachine\Root` for the self-signed Root CA cert; throttled `gpupdate` (90×20s = 30 min) | `machine_cert` | clean signal |
| **Machine cert issued** | web1, manage1 → issueca (autoenroll) | poll `Cert:\LocalMachine\My` for a Server-Auth EKU cert (90×20s) | `machine_cert` | clean signal |
| **Template replication** | cert_templates(_pqc) → issueca(/-pqc) AD | `Get-ADObject` replication wait before ACL apply (15×4s) | `cert_templates`, `cert_templates_pqc` | clean signal |
| **CMS-lab CSR → issuing CA (Linux)** | scanner1 → issueca(/-pqc) | **forward signal**: poll web1's CDP for the issuing CA's CRL until 200 (90×20s), *then* submit the delegated CSR (40×30s backstop). The CRL 200 proves the CA is installed, running, and past its reboot. | `cms_lab_linux` | clean signal (forward) |
| **CMS-lab enroll (Windows)** | manage1 → issueca(/-pqc) | local `certreq -submit` as SYSTEM, retried until the CA issues (10×30s); no CDP gate | `cms_lab_windows` | bounded retry |
| **Linux → step-ca ACME** | acme1 → stepca1 | `wait_for` port 9000 before ACME | `acme_client` | clean signal |
| **Linux → step-ca ACME** | observe1 → stepca1 | `getent hosts` DNS retry (15×4s) before ACME; no port wait | `observe_tls` | bounded retry |
| **Linux → AD DNS** | observe1, acme1 → dc1 | `delegate_to: dc1` + `Add-DnsServerResourceRecordA`, gated `when: 'dc1' in groups['all']` | `observe1.yml`, `acme1.yml` | clean signal |

## Status

- **30 edges, 28 clean-signal gated, 2 bounded-retry, 0 ungated sleeps.** Every
  `Start-Sleep` in the Ansible tree is a poll interval in a bounded `until`/wait
  loop (C1–C12 campaigns + v2.1.5 readiness-gates work). The two bounded-retry
  edges (table above) are `cms_lab_windows`'s local enroll and `observe_tls`'s
  DNS-only ACME wait — single-host waits with no clean signal available.
- **The Linux CMS-lab CSR submit is covered by a forward gate.** The CDP
  CRL forward-gate for the same CA (`cms_lab_linux`/`certs.yml`) precedes the
  delegated `certreq -submit`; its 40×30s `until` is a backstop. A pre-submit
  `certutil -ping` would be redundant and risks the unreachable-host trap. No action.

## Residual backlog (not cross-VM edges)

Two remaining cold-build blockers are not readiness edges:

1. **manage1 empty-subject autoenrollment-race certs.** Autoenrollment firing
   mid-provision (during the RSAT install), before template attributes materialize,
   leaves an empty-Subject / no-EKU cert in `LocalMachine\My`; harmless, but
   `validate.sh` fails cert-hygiene (duplicate/empty subject) each fresh cold build.
   **Fixed**: idempotent post-enrollment cleanup in `machine_cert` (guard: empty
   Subject *and* zero EKUs, never matching the real machine cert).
2. **The VBox / host-env glitch class** — not lab logic. Dangling `vboxsf` mounts
   (`C:\Software` empty after a reboot) are mitigated by `shared_folder_repair`
   (idempotent symlink teardown + rebuild), wired at both reboot points
   (`domain_join` post-reboot, `windows_kb_install` post-3010-reboot), safe to call
   defensively before any cache-first role. `VERR_SVM_HOST_SVME_NOT_ENABLED` (KVM
   modules squatting on AMD-V): `sudo modprobe -r kvm_amd kvm` on the host; see
   `docs/kvm-amd-v-vbox-blocker.md`.

## Definition of done

**Three consecutive first-try-clean `pqc-full` cold builds** — each `failed=0`, no
manual intervention, no *lab-logic* race. Pure VBox/host-env glitches (`VERR_SVM`, a
dangling mount `shared_folder_repair` then fixes) are excluded, not counter-resetting.
If a VM *hangs* (not fails), the known lever is capping `up.sh` Phase-3 concurrency —
not applied speculatively (trades parallelism against a glitch that has not recurred).

## Campaign 2: simultaneous multi-profile cold-start (2026-07-09)

The single-profile criterion above was met 2026-07-08 on v2.4.0; this campaign adds
**concurrency**: one round = `pqc-full`, `ad-cs-one-tier`, and `core` cold-built
**simultaneously** (launches staggered ~25s so Phase-1 creates overlap) on one host,
standing `ad-cs-two-tier` lab untouched. Rationale: the 2026-07-06 incident cluster
(#210–#219) was entirely concurrency-borne — transient machine-lock collisions,
subnet/port races, observer misbinding — paths single-profile green does not certify.

**Kill criterion:** one round, all three first-try clean (up.sh rc=0, every VM OK,
zero reruns). A pure host/VBox environment glitch or operator action is excluded and
reruns the round; an organic failure is fixed on this branch, then the round repeats.
Evidence: `vagrant/logs/triple-round-<n>/` (per-profile up console, nuke log, verdict
file — local build logs, not in the repo).

### Result: CRITERION MET — round 1, first attempt (2026-07-09)

All three cold-built simultaneously (launches 05:44–05:46, Phase-1 creates fully
overlapped, 21 VMs beside the untouched `ad-cs-two-tier` lab); every VM
first-attempt clean, zero reruns:

| Profile | Total | Slowest VM | Verdict |
|---|---|---|---|
| `pqc-full` (13 VMs) | 108m 47s | manage1 64m 29s | CLEAN |
| `ad-cs-one-tier` (4 VMs) | 63m 46s | web1 33m 50s | CLEAN |
| `core` (4 VMs) | 63m 26s | web1 33m 50s | CLEAN |

Concurrency tax vs solo baselines: pqc-full +15% (94m solo), 4-VM profiles +20%
(53m solo) — pure host contention, no retry activity. **Zero transient machine-lock
collisions** across all 21 create sequences: the v2.2.3 + #212 lock-retry /
cycle-guard machinery was armed, never provoked; sequential per-lab creates plus the
25s stagger appear to keep flock windows disjoint in practice. Evidence:
`vagrant/logs/triple-round-1/` + logdirs `20260709-054719` / `-054530` / `-054556`
(local build logs, not in the repo).
