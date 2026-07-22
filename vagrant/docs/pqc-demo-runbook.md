# PQC Migration Demo Runbook

Demo playbook for a PKI-literate audience; assumes a built lab (`up.sh`
complete, all VMs green per `validate.sh`). CBOM pipeline architecture:
[cbom-pipeline.md](cbom-pipeline.md). Chimera catoken workaround:
[ejbca-chimera-setup.md](ejbca-chimera-setup.md).

---

## Known Limitations (read this first)

AD CS ML-DSA issuance (CA + leaf) ships in full; two genuine upstream gaps remain — GnuPG ML-DSA signing and OpenSSL's permissive `-Verify`.

**1. Microsoft AD CS ML-DSA issuance — CA + leaf certs both ship today**

Windows Server 2025 ships ML-DSA + ML-KEM primitives in CNG (Cryptography Next Generation); the **KB5087539** cumulative (May 2026) added ML-DSA support to AD CS itself. The lab stands up a **native Microsoft ML-DSA CA hierarchy** under the **`pqc-adcs-two-tier`** profile:

- **`rootca-pqc`** — standalone offline ML-DSA-87 root CA (`standalone_ca` role, ML-DSA mode).
- **`issueca-pqc`** — domain-joined enterprise ML-DSA-65 issuing CA chained off the PQC root (`subordinate_ca` role, ML-DSA mode).

Both are provisioned by the unified `ansible/playbooks/ca.yml` (ML-DSA mode via `ca_crypto_provider`), after the `windows_kb_install` role / `install-windows-kb.yml` playbook installs KB5087539 (cache-first, reboots on a 3010 return). `ca.yml` publishes CDP/AIA + CRL, then runs `cert_templates_pqc` to publish an ML-DSA-65 Server-Auth leaf template and prove issuance — AD CS natively issues both ML-DSA *CA* and *service* certs. EJBCA additionally issues PQC leaves, and the EJBCA-Chimera-Root-CA is distributed to Windows hosts via Group Policy / Configuration NC, giving services like IIS a chimera leaf (RSA primary + ML-DSA-65 alt-sig). `pqc-adcs-audit.yml` reports the state of the CNG / CertEnroll / AD CS / Schannel layers.

**2. GnuPG ML-DSA signing — pending GnuPG 2.6.x**

The lab builds GnuPG 2.5.13 from source for the OpenPGP PQC story. Kyber-768 subkey encryption works and ships in the demo; ML-DSA signing is not in the 2.5.x branch (2.6.x roadmap, no release date), so "PQC-signed git commits / package signatures" isn't yet demonstrable. See [gnupg-pqc-status.md](gnupg-pqc-status.md).

**3. OpenSSL 3.5 TLS 1.3 `-Verify 1` is permissive (upstream quirk)**

The mTLS demo on observe1:8445 uses `openssl s_server -Verify 1` to require a client certificate, but OpenSSL 3.5's TLS 1.3 sends a CertificateRequest, tolerates an empty client Certificate response, and completes the handshake anyway (known upstream behavior, not a bug — they cite "TLS 1.3 design separation of authentication and key establishment"). Assert the positive signal: the server-side journal entry `depth=0 CN=scanner1` proves the ML-DSA-65 client cert was received, parsed, and chain-validated against EJBCA-PQC-Issuing-CA. Handshake failure can't be the negative signal.

Component status pages to open before the demo:
- [tomcat-pqc-status.md](tomcat-pqc-status.md) — BouncyCastle 1.81 TLS cipher-suite filter blocks pure-ML-DSA serving on Tomcat. Mitigations + 1.82 roadmap.
- [gnupg-pqc-status.md](gnupg-pqc-status.md) — full GnuPG 2.5.x scope details.

---

## PQC Migration Orchestrator (canonical path)

The canonical end-to-end path is `vagrant/ansible/playbooks/pqc-migrate.yml`,
importing five per-phase playbooks in dependency order, each runnable alone:

| Phase | Playbook | What it does |
|---|---|---|
| 1. Foundation | `pqc-migrate-foundation.yml` (wraps `pqc-ejbca.yml`) | Creates EJBCA's PQC + chimera CAs; verifies the three CA certs exist and are ML-DSA-65 signed |
| 2. TLS | `pqc-migrate-tls.yml` (wraps `pqc-pure-leaf.yml` + `pqc-chimera.yml`) | Pure-PQC leaves on observe1:8444 / stepca1:9444 / ejbca1:8444 / hydra1:8444, chimera leaves on observe1+web1, AD Trusted Root distribution via dc1 |
| 3. SSH | `pqc-migrate-ssh.yml` (wraps `pqc-ssh.yml`) | Builds OpenSSH 10 + sshd-pqc on the four PQC SSH targets; verifies binary, KEX support, live negotiation |
| 4. GPG | `pqc-migrate-gpg.yml` (wraps `pqc-gnupg.yml`) | Builds GnuPG 2.5 + Kyber composite key on the four PQC GPG targets; verifies keyring + Kyber round-trip |
| 5. Posture | `pqc-migrate-posture.yml` | Runs the CBOM scanner sweep (rescan-only) to ingest fresh posture into OpenSearch |

Usage against a live `pqc-full` lab:

```bash
cd vagrant
LAB_PROFILE=pqc-full ansible-playbook \
  -i ansible/inventory/pqc-full/pqc.ini \
  ansible/playbooks/pqc-migrate.yml
```

`lib/render_inventory.rb` renders `ansible/inventory/<profile>/pqc.ini` per
profile (replacing the old hand-maintained top-level `pqc.ini`); `up.sh` / the
Vagrant provisioner handle this automatically. Standalone runs: group_vars
gotcha, see "If anything's red" → *`psf_init`/`schtask_admin_init` undefined*.

Each phase cheaply re-verifies completed work on re-run, so after a partial
failure the orchestrator re-verifies green phases and re-runs the failed one;
individual `pqc-*.yml` playbooks remain useful for troubleshooting.

The per-phase wire checks (SSH KEX, GPG Kyber round-trip, pure-PQC TLS leaf)
source `vagrant/scripts/lib/pqc-verify/{ssh-kex,gpg-kyber,tls-pure-leaf}.sh`,
the same probes `validate.sh` consumes via `scripts/checks/`, so the two
cannot drift. Verify-harness before/after:
[docs/architecture-evolution.md](../../docs/architecture-evolution.md).

## What this lab is showing

A multi-year transition, shown end to end: **inventory** every cryptographic
asset ("CBOM"), **score** each as quantum-vulnerable, quantum-safe, or
weak-classical (already broken), **migrate** — often via transitional
dual-signature ("chimera") certificates — and **verify** the wire changed,
across TLS, SSH, and OpenPGP (four live pure-PQC TLS endpoints, four PQC-KEX
SSH endpoints, a Kyber-768 OpenPGP key).

## The five-scanner story

Six CBOM scanners ship in the pipeline; this demo exercises the five below in
parallel (`theia`, the static file scanner, is not part of the live demo loop),
each a different view of the same lab; the demo highlights the gap between them.

| Scanner | What it sees | Typical lab safe% | Story |
|---|---|---|---|
| `nmap-network` | Live TLS on the wire as a stock client sees it | ~2% | "What's the wire reality? Almost everything is still classical." |
| `ejbca-api` | EJBCA's CA inventory via SSH + `ejbca.sh` CLI (deliberately bypasses TLS) | ~42% | "What machinery exists for issuing PQC certs? We have 2 ML-DSA CAs and a chimera root, but they're not yet the ones signing service certs." |
| `pqc-handshake` | TLS endpoints as a *PQC-aware* (OpenSSL 3.5) client sees them | ~44% | "What's actually live AND PQC-protected on TLS? Four pure-PQC + chimera endpoints, intentionally invisible to legacy clients." |
| `pqc-ssh` | SSH KEX algorithms as a PQC-aware (OpenSSH 10) client sees them | ~67% | "Same question for SSH. Mostly safe — `mlkem768x25519-sha256` (NIST) and `sntrup761x25519-sha512@openssh.com` (pre-standard) both negotiate." |
| `pqc-openpgp` | OpenPGP subkeys per host as GnuPG 2.5 reports them | ~50% | "Same question for encryption-at-rest. Four hosts each have an Ed25519 primary + Kyber-768 hybrid subkey — Kyber-half stays safe even if Ed25519 breaks." |

Headline talking point: **`nmap-network` and `pqc-handshake` disagree about
the same machine** — observe1:8444/8445 are invisible to nmap (its OpenSSL 3.0
can't handshake with an ML-DSA-65 cert) yet are the *first* endpoints a
PQC-aware scanner finds; likewise stock `ssh -Q kex` doesn't list
`mlkem768x25519-sha256` until OpenSSH 10+ (`pqc-ssh`'s view).

## The endpoint topology

Four layers of PQC posture coexist on a single demo box (observe1):

| URL | Cert | Story |
|---|---|---|
| `https://observe1.yourlab.local/` (:443) | step-ca ACME ECDSA | The "today" story — a real production-grade ACME-issued cert, classical. |
| `https://observe1.yourlab.local:8443/` | EJBCA chimera (RSA + ML-DSA-65 alt-sig extensions 2.5.29.73/74) | The "transition" story — backwards-compatible to RSA-only clients, PQ-safe to alt-sig-aware ones. |
| `https://observe1.yourlab.local:8444/` (openssl s_client only) | EJBCA pure ML-DSA-65 | The "destination — server auth" story — PQ-only, legacy clients explicitly cannot reach. |
| `https://observe1.yourlab.local:8445/` (PQC-aware mTLS client only) | Server: pure ML-DSA-65 · Client: pure ML-DSA-65 | The "destination — mutual auth" story — both sides of the handshake are PQC. |

Three other VMs serve a pure-PQC twin on a parallel port for breadth:

| Endpoint | Behind | Purpose |
|---|---|---|
| `192.168.56.51:9444` | stepca1 (alongside step-ca on :9000) | "PKI control plane itself can be PQC" |
| `192.168.56.50:8444` | ejbca1 (alongside EJBCA web on :8443) | "EJBCA itself can serve PQC" |
| `192.168.56.52:8444` | hydra1 (alongside Hydra OAuth on :4444) | "OAuth/OIDC can be PQC" |

All four share one recipe: pure ML-DSA-65 leaf issued by
`EJBCA-PQC-Issuing-CA` (SERVER cert profile), served as a systemd unit by
`openssl s_server` (OpenSSL 3.5 — vanilla nginx 1.27 can't load ML-DSA keys).
To add a host: add it to `pqc_pure_leaf_endpoints` in `lib/render_inventory.rb`'s
`PQC_GROUPS` (not the rendered, overwritten `ansible/inventory/<profile>/pqc.ini`),
re-render, re-run `pqc-pure-leaf.yml`.

### The mTLS variant: observe1:8445

The :8445 listener serves the same ML-DSA-65 server cert as :8444 but adds
`-Verify 1` to `s_server` — the **client** must present a cert chaining to
`EJBCA-PQC-Issuing-CA`; scanner1 holds it (ENDUSER profile → Client Auth EKU).

| Field | Server (observe1) | Client (scanner1) |
|---|---|---|
| Leaf cert | ML-DSA-65 | ML-DSA-65 |
| Issuer | EJBCA-PQC-Issuing-CA | EJBCA-PQC-Issuing-CA |
| EKU | Server Auth | Client Auth |
| Cert profile | SERVER | ENDUSER |

Recipe: `pqc-mtls.yml` (one playbook, four plays: enroll client cert on
scanner1, stand up the mTLS listener on observe1, probe from scanner1,
summary on localhost). **openssl 3.5 caveat:** per Known Limitations #3,
`s_server -Verify` tolerates an empty `Certificate` response — assert the
positive signal; strict rejection needs a real web server (nginx) with proper
TLS 1.3 mTLS.

## The Windows side: chimera on IIS

`web1` is the Windows twin of `observe1` for the chimera story: same
EJBCA-Chimera-Root-CA, RSA-primary leaf with ML-DSA-65 alt-sig extensions, but
the TLS terminator is **IIS/Schannel** instead of nginx:

| URL | Cert | Story |
|---|---|---|
| `https://web1.yourlab.local:8443/` | EJBCA chimera | Proves AD-joined Windows servers can already do transitional PQC via Schannel today. (AD CS issues ML-DSA *CA* and *leaf* certs under the `pqc-adcs-two-tier` profile via `cert_templates_pqc`; the chimera dual-sig service leaf still comes from EJBCA, since Schannel can't emit alt-sig certs.) |

Schannel handshakes on the RSA primary sig (rsassaPss) and ignores the alt-sig
extensions; PQC-aware wire inspectors verify ML-DSA-65 from the same cert. IIS
binds the **PKI site** (AD CS CRL distribution) on :8443, so the same server
serves both the CRLs and the chimera leaf.

## Forest-wide chimera trust (no per-machine import)

Every AD-joined Windows machine trusts `EJBCA-Chimera-Root-CA` via AD's
Configuration NC / built-in Enterprise Trust group policy. One step on dc1:

```powershell
certutil -dspublish -f chimera-root-ca.cer RootCA
```

Same mechanism AD CS uses for its own root; machines pick it up on the next
`gpupdate /force` (or the 90-min auto refresh). `pqc-chimera.yml`'s final play
runs it via the parameterized `ejbca_ad_trust` role — browsers on manage1
(and client1 in the `full` profile) then trust observe1:8443, web1:8443, and
any future chimera endpoint.

## Beyond TLS: SSH PQC KEX

Stock Ubuntu 22.04's OpenSSH 8.9p1 has the pre-standard PQC KEX
(`sntrup761x25519-sha512@openssh.com`, NTRU-Prime hybrid) but not
NIST-standardized `mlkem768x25519-sha256` (OpenSSH default since 10.0 /
Apr 2025). The `openssh_pqc` role builds OpenSSH 10.0p2 from source to
`/opt/openssh-10` on each Linux PQC host, with a parallel `sshd-pqc` unit on
**:2222** (system sshd on :22 untouched) advertising `mlkem768x25519-sha256`
first — live on **all four** hosts:

| Endpoint | Default sshd KEX | New :2222 sshd-pqc KEX |
|---|---|---|
| observe1:2222, stepca1:2222, ejbca1:2222, hydra1:2222 | sntrup761 (pre-standard) | **mlkem768x25519-sha256** (NIST) |

Wire-level proof: `/opt/openssh-10/bin/ssh -v -p 2222 -o
KexAlgorithms=mlkem768x25519-sha256 nobody@127.0.0.1` returns
`debug1: kex: algorithm: mlkem768x25519-sha256`. Auth fails by design
(BatchMode + nobody user) — KEX negotiation is what's being proved.

The `pqc-ssh` CBOM scanner runs on observe1 (the only host with an OpenSSH 10
*client*), probes each `:2222` endpoint for mlkem768/sntrup761/curve25519, and
tags component names `[PQC-STANDARD]` / `[PQC-LEGACY]` for the OSD dashboards.

## Beyond TLS+SSH: OpenPGP PQC encryption

RFC 9580 (OpenPGP, June 2024) standardized both ML-KEM and ML-DSA. As of
GnuPG 2.5.19 (May 2026 latest), **ML-KEM (Kyber-768) encryption is shipped;
ML-DSA signing is not** — see [gnupg-pqc-status.md](gnupg-pqc-status.md).

The `gnupg_pqc` role builds the GnuPG 2.5.13 + libgcrypt 1.11.2 stack from
source to `/opt/gnupg-pqc` on each Linux PQC host. Per-host PGP key: Ed25519
primary (sign+cert, classical) + `ky768_bp256` (Kyber-768 + Brainpool P-256
hybrid, PQC) encryption subkey.

Round-trip demo:
```
HOMEDIR=/opt/gnupg-pqc/home GPG=/opt/gnupg-pqc/bin/gpg
echo 'top secret' | sudo $GPG --homedir $HOMEDIR --trust-model always \
    -e -r pqc@yourlab.local -o /tmp/secret.gpg
sudo $GPG --homedir $HOMEDIR --list-packets /tmp/secret.gpg \
    # → shows "encrypted with ky768_bp256 key"
sudo $GPG --homedir $HOMEDIR --batch --pinentry-mode loopback \
    --passphrase '' -d /tmp/secret.gpg
```

Demo angle: payloads wrapped to the Kyber subkey (backups, git secrets, mail)
get a quantum-safe session key — if the Brainpool half breaks, the Kyber half
holds.

## Pre-flight (one-time per session)

```bash
cd vagrant
LAB_PROFILE=pqc-full vagrant status
LAB_PROFILE=pqc-full bash scripts/validate.sh   # expect ~231 PASS / 0 FAIL / 2 SKIP
```

The 2 SKIPs are the out-of-profile one-tier VMs (`ca1`, `client1`). If any of
the four `cloudflare_pqc-*` checks (`report`, `pqc-negotiated`, `timer`,
`opensearch-ingest`) FAIL on a freshly-built or long-idle lab, the
public-endpoint probe report is likely stale — `cloudflare_pqc-report` enforces
a 12h freshness threshold — re-run the probe and they go green:
`vagrant ssh scanner1 -c 'sudo systemctl start cloudflare-pqc.service'`.

If anything's red, re-run the orchestrator's relevant phase first — it
re-verifies in dependency order and won't leave a half-fixed lab. Direct
playbook invocation is a fallback to isolate a single component:

- **ACME cert expired (lab idle >24h):** usually **self-heals — no action
  needed**. The `acme-renew` boot unit fires `OnBootSec=5min`, re-issuing the
  :443 cert within ~5 minutes of a cold start (`acme-renew.timer` then renews
  every 4h). Only if you need the cert *immediately* (before the 5-min boot
  timer): `vagrant provision observe1` re-issues on demand.
- **CRL refresh (online issuing CAs):** `ca_crl_republish` runs a daily
  `certutil -CRL` + web1 republish on `issueca`/`issueca-pqc`/`ca1`; the
  26-week CRL validity is a cushion, not the refresh mechanism. The ML-DSA
  hierarchy publishes to its own CDP/AIA namespace
  (`http://pki.<domain>/crl/pqc` + `/aia/pqc` vs the classical `/crl` +
  `/aia`, via `publish_subdir`), so a refresh or revocation in one hierarchy
  never touches the other's namespace.
  Full revocation lifecycle (enroll → `certutil -revoke` → republish →
  `CRYPT_E_REVOKED`): [adcs-functest revocation walkthrough](../../docs/walkthroughs/labs/adcs-functest-4-revocation-walkthrough.md);
  per-anchor trust-distribution
  map: [ARCHITECTURE.md](../../ARCHITECTURE.md) → *Trust anchor distribution
  & revocation*.
- **CRL expired (lab idle >~6 months):** CRL period is 26 weeks uniformly
  (`enterprise_ca` + `subordinate_ca` CAPolicy.inf); republish manually per CA
  VM: `vagrant winrm ca1 -c 'certutil -crl'` (same for `issueca`/`rootca`).
- **A pure-PQC endpoint or chimera leaf missing (TLS phase):** re-run Phase 2 —
  `ansible-playbook -i ansible/inventory/pqc-full/pqc.ini ansible/playbooks/pqc-migrate-tls.yml`
  — or invoke `pqc-pure-leaf.yml` / `pqc-chimera.yml` directly.
- **`psf_init`/`schtask_admin_init` undefined (standalone `pqc-migrate.yml`):**
  standalone runs against `ansible/inventory/<profile>/pqc.ini` used to abort
  on the Windows chimera-trust play with `'psf_init' is undefined` —
  `lib/render_inventory.rb`'s `STATIC_OWNED` drops `psf_init` (and
  `pwsh_version`, `lab_timezone*`) from the generated
  `inventory/<profile>/group_vars/all.yml`, and `schtask_admin_init` lives only
  in the checked-in `ansible/group_vars/all.yml`, which a bare `-i .../pqc.ini`
  run doesn't auto-discover. **Fixed:** the chimera-trust play now loads
  `ansible/group_vars/all.yml` via a play-level `vars_files` fallback (Vagrant
  extra_vars still win); older checkouts: pass `-e 'psf_init=…'
  -e 'schtask_admin_init=…'`.
- **SSH / GPG / scanner posture issues:** re-run the matching phase playbook
  (`pqc-migrate-ssh.yml`, `pqc-migrate-gpg.yml`, `pqc-migrate-posture.yml`).

## The demo loop

Clean-state demo (recommended for the first run of a session):

```bash
cd vagrant
LAB_PROFILE=pqc-full bash scripts/pqc-remediate.sh --rescan-only --reset
```

`--reset` wipes and recreates the OpenSearch `cbom` index before ingesting —
use it when dashboards must reflect *only* the current run; old data can carry
pre-fix classifier output that pollutes the "PQC Status" pie with `unknown`.

Incremental demo (subsequent runs in the same session):

```bash
LAB_PROFILE=pqc-full bash scripts/pqc-remediate.sh --rescan-only
```

Both invocations run Phase 3 (rescan) + Phase 4 (compare/score/ingest) for all
three scanners. Expected output:

1. **nmap-network** — `LAB TOTAL ~1.2% RED` — wire-classical reality.
2. **ejbca-api** — `LAB TOTAL ~41.7% RED` — control-plane PQC machinery.
3. **pqc-handshake** — `LAB TOTAL ~45% RED` — what's actually PQC on the wire
   to a PQC-aware client. observe1 should show `~37.5%` safe% (3 of 8
   components quantum-safe — the ML-DSA-65 cert + its sig algo + pubkey).

All three scanners ingest into OpenSearch with `cbom_event_type: pqc-rescan`.

## What to show in OpenSearch Dashboards

Open https://192.168.56.53/app/dashboards (the `observe_tls` nginx front on
:443; the raw :5601 listener is loopback-only). Set time picker to "Last 1
hour" so only fresh post-classifier-fix data shows.

| Dashboard | What to point out |
|---|---|
| **CBOM: PQC Readiness Scorecard** (`cbom-dash-4`) | The headline. Top-left "Pure-PQC Endpoints" metric reads **4** — observe1:8444, stepca1:9444, ejbca1:8444, hydra1:8444. PQC-per-VM stacked bar shows observe1's mixed posture (classical + chimera + pure-PQC coexisting). web1 and observe1 both light up with chimera certs visible to all three scanners. |
| **CBOM: Crypto Posture Overview** (`cbom-dash-1`) | Algorithm distribution pie shows ML-DSA-65 alongside RSA/ECDSA — both old and new world side by side. |
| **CBOM: Drift Detection** (`cbom-dash-3`) | Filter by `cbom_event_type:diff-added` to see what new components landed in the last sweep. Useful after re-running the demo loop a second time — should be near-empty (no drift). |
| **CBOM: Certificate Lifecycle** (`cbom-dash-2`) | Cert issuer breakdown shows `EJBCA-PQC-Issuing-CA` issuing real leaves now, not just sitting in the CA inventory. |
| **CBOM: Certificate Expiry & Health** (`cbom-dash-5`) | Operational view — any expired certs, self-signed, expiring soon. |
| **CBOM: VM Security Posture** (`cbom-dash-6`) | Per-VM crypto inventory. Hover the heatmap to see which VMs are touched by which sig algorithms. |

## Talking points / Q&A prep

**"Why isn't observe1:8444 in the nmap scan?"**
nmap on scanner1 uses system OpenSSL 3.0, which has no ML-DSA support —
negotiation fails before it can see the cert. Hence the second scanner,
`pqc-handshake`, built on OpenSSL 3.5 (mainline ML-DSA since May 2025).

**"So a pure-PQC service is unreachable by today's clients?"**
Mostly yes — hence chimera/dual-signature certs: an RSA primary signature AND
an ML-DSA-65 alt-signature in one cert. Old clients verify the RSA side and
ignore unknown extensions; new clients verify the ML-DSA side. observe1:8443
is that bridge; pure-PQC (:8444) is the destination state.

**"What about git commit signing with PQC?"**
No released GnuPG (through 2.5.19, May 2026) implements RFC 9580 ML-DSA
signing — only ML-KEM/Kyber encryption shipped. Paths forward: GnuPG 2.6.x,
Sequoia-PGP, libgcrypt directly. See [gnupg-pqc-status.md](gnupg-pqc-status.md).

**"What about Tomcat (Java)? Web1 / IIS?"**
No pure-PQC Tomcat connector yet: the cert + PKCS12 keystore are ready on
`tomcat1:C:\PqcCerts\tomcat1-pqc.p12`, but BouncyCastle 1.81 + Java 17 can't
serve an ML-DSA leaf — BC's server-side cert/cipher-suite matching rejects all
TLS 1.3 suites for it. Notes + paths forward (BC 1.82+, Java 25 LTS, or an
OpenSSL 3.5 reverse proxy): [tomcat-pqc-status.md](tomcat-pqc-status.md).
Web1/IIS has the same Schannel limitation as AD CS.

**"Where does Microsoft AD CS fit?"**
First-class part of the lab. CNG ships ML-DSA on Server 2025 patched past
KB5068861 (Nov 2025); KB5087539 (May 2026) extends ML-DSA up into AD CS. The
native hierarchy is detailed under Known Limitations #1 above.

**"Why are some scanner totals 'unknown'?"**
Should be ~0 in a clean-state demo; meaningful counts mean stale pre-fix docs
in the OSD index — run `pqc-remediate.sh --rescan-only --reset`.

## Common gotchas

- **`vagrant ssh ejbca1` may talk to dc1.** Multiple VMs default to NAT port
  2222; the first to bind wins. Use direct SSH via the host-only IP
  (`192.168.56.50` for ejbca1, etc.) — `validate.sh` already does this.
- **Re-enrolling a host with a different cert profile.** `addendentity`
  silently no-ops if the username is taken, which can leave wrong-EKU certs;
  `ejbca_pqc_enroll` deletes the existing end-entity when a profile is
  specified.
- **OSD shows lots of "unknown" on certs.** Pre-fix data — re-run the demo
  loop and filter dashboards to "Last 1 hour".
- **observe1:443 ACME cert just expired.** 24h cert lifetime; a lab offline
  >24h may be past the 4h renew window — `vagrant provision observe1`
  re-issues.

## Files / references for further digging

- `vagrant/ansible/playbooks/pqc-migrate.yml` — canonical end-to-end migration orchestrator (5 phases)
- `vagrant/ansible/playbooks/pqc-migrate-{foundation,tls,ssh,gpg,posture}.yml` — per-phase entry points
- `vagrant/scripts/pqc-remediate.sh` — CBOM rescan / scoring helper (called by Phase 5)
- `vagrant/scripts/cbom-pipeline.sh` — per-scanner pipeline
- `vagrant/cbom-toolkit/python/pqc_handshake_probe.py` — the pure-PQC scanner
- `vagrant/cbom-toolkit/python/pqc_classify.py` — single source of truth for PQC classification
- `vagrant/cbom-toolkit/python/osd_dashboards.py` — dashboard definitions
- `vagrant/ansible/playbooks/pqc-pure-leaf.yml` — pure-PQC endpoint enrollment (called by Phase 2; also usable standalone for troubleshooting)
- `vagrant/ansible/playbooks/pqc-chimera.yml` — chimera leaf + AD root distribution (called by Phase 2)
- `vagrant/ansible/inventory/<profile>/pqc.ini` — generated per-profile PQC inventory (`pqc_pure_leaf_endpoints` group); edit `vagrant/lib/render_inventory.rb` `PQC_GROUPS`, not the rendered file
- `vagrant/scripts/lib/pqc-verify/{ssh-kex,gpg-kyber,tls-pure-leaf}.sh` — shared wire probes consumed by both `validate.sh` (`scripts/checks/`) and the `pqc-migrate-*.yml` phases
- `vagrant/ansible/roles/ca_crl_republish/` — daily `certutil -CRL` + web1 republish on online issuing CAs; `publish_subdir` selects the classical vs `pqc` CDP/AIA namespace
- `vagrant/ansible/roles/openssl_pqc_demo/` — systemd-managed `s_server` role
- `vagrant/ansible/roles/openssl_35/` — OpenSSL 3.5 install
