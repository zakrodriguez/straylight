# Straylight PKI Lab

A reproducible PKI lab for **PKI learning** and **post-quantum migration**: Windows AD CS, EJBCA Community Edition, and Smallstep step-ca side by side, plus pure-PQC (ML-DSA-65) TLS endpoints, chimera certificates, OpenSSH ML-KEM hybrid KEX, OpenPGP Kyber subkeys, and CBOM scanners feeding an OpenSearch crypto observatory.

> [ARCHITECTURE.md](ARCHITECTURE.md) — diagrams, VM inventory, PQC feature matrix · [docs/how-it-works.md](docs/how-it-works.md) — end-to-end lab session flow · [docs/configuration.md](docs/configuration.md) — configuration options · [docs/architecture-evolution.md](docs/architecture-evolution.md) — design rationale

## Who this is for

- **Learn PKI.** Run AD CS, EJBCA, and step-ca side by side; compare web enrollment, NDES, ACME, CRL/AIA, key archival. Start with `LAB_PROFILE=ad-cs-two-tier`.
- **Plan a PQC migration.** ML-DSA-65 leaf certs, chimera (RSA + ML-DSA alt-sig) certs, hybrid KEX over TLS/SSH, Kyber-768 OpenPGP — measured and dashboarded via CycloneDX CBOM. Start with `LAB_PROFILE=pqc-full` (Windows side) or `pqc-linux` (Linux only).

## What's inside

- **Vagrant** — 14 lab profiles, one Vagrantfile + composable YAML profiles
- **VirtualBox** — free hypervisor
- **Ansible** — 69 reusable roles cover every VM type
- **PowerShell** — Windows / AD CS automation (two-tier CA provisioning)
- **OpenSSL 3.5 + EJBCA 9.3 + step-ca 0.30** — PQC-ready crypto stack on Linux
- **Packer** — optional custom base images

## Requirements

- **Host OS**: Linux only — Ubuntu 22.04+ (tested baseline). Windows and macOS were evaluated and declined (no VirtualBox Apple-Silicon support; WSL2 host-only networking is unguaranteed — see [ARCHITECTURE.md → Host platform](ARCHITECTURE.md#host-platform)). From those, run Straylight inside a Linux VM or on a remote Linux host.
- **RAM**: 16GB minimum, 32GB+ recommended
- **Disk**: 100GB+ free (200GB+ with WSUS)
- **CPU**: 4+ cores recommended
- **Ansible**: 2.14+ with collections (`ansible-galaxy collection install -r vagrant/ansible/requirements.yml`)

## Quick Start

### 1. Host setup

```bash
./scripts/install-wizard.sh
```

The wizard checks/installs prerequisites (VirtualBox, Vagrant, Ansible), prompts for domain name, network prefix, and admin password, lets you pick a lab profile, and optionally starts deployment. Windows Server version is env-only (`WIN_SERVER_VERSION`, default 2025).

Manual alternative:

```bash
./scripts/install-wizard.sh --prereqs-only
ansible-galaxy collection install -r vagrant/ansible/requirements.yml
# Log out and back in for group membership
```

### 2. Deploy a lab profile

Each profile is a YAML file in `vagrant/profiles/` declaring which VMs and resources build.

```bash
cd vagrant

./up.sh                                  # default `core` — DC + CA + IIS + RSAT workstation
LAB_PROFILE=ad-cs-two-tier ./up.sh       # two-tier AD CS (offline root + issuing CA)
LAB_PROFILE=ad-cs-minimal ./up.sh        # smallest AD CS demo (~3 GB RAM, 3 VMs)
LAB_PROFILE=pqc-linux ./up.sh            # pure PQC demo — no Windows
LAB_PROFILE=full ./up.sh                 # all always-on VMs (18)
LAB_COMPONENTS=observe1,scanner1,stepca1 ./up.sh   # ad-hoc component list

./up.sh --list-profiles                  # profile catalog
./up.sh --show-profile pqc-linux         # inspect without building
```

Each profile gets its own `.vagrant-<profile>/` dotfile directory, so multiple profiles coexist on the same host without collisions.

### 3. Validate

```bash
bash vagrant/scripts/validate.sh    # profile-aware — skips absent VMs
```

### Common operations

```bash
cd vagrant
vagrant status
vagrant rdp manage1            # RDP to the RSAT management workstation
vagrant provision ca1          # re-run provisioning on one VM
./snap.sh save dc1 ca1         # snapshot before testing
./snap.sh restore dc1 ca1
./nuke.sh --confirm            # tear down active profile only (won't touch others)
```

## Lab Walkthroughs

Once a profile is up, [`docs/walkthroughs/`](docs/walkthroughs/) holds hands-on labs paired 1:1 with [fixmycert.com](https://fixmycert.com) and [gradenegger.eu](https://www.gradenegger.eu) guides, each with a self-check quiz and module exam. The repo currently ships one representative module — the **AD CS functional test** (4 numbered labs: service health → connectivity → issuance → revocation). The full catalog (80+ labs across ~22 modules) is being hands-on verified in the development archive and returns module-by-module. See [`docs/walkthroughs/README.md`](docs/walkthroughs/README.md).

## Lab Profiles

Profiles live in `vagrant/profiles/*.yml`. Resolution priority (lowest → highest): default `core` → `LAB_PROFILE` → `LAB_COMPONENTS`.

| Profile | VMs | Use case |
|---|---|---|
| `core` | 4 | Default — DC + CA + IIS + RSAT workstation |
| `ad-cs-minimal` | 3 | Smallest viable AD CS demo (~3 GB RAM) |
| `ad-cs-one-tier` | 4 | Single Enterprise CA |
| `ad-cs-two-tier` | 5 | Offline root + issuing CA, production-realistic (~45-50 min cold build) |
| `ejbca-only` | 2 | EJBCA CE only, no AD |
| `stepca-only` | 3 | step-ca + ACME demo, no AD |
| `oauth-oidc` | 3 | Ory Hydra OAuth/OIDC + step-ca TLS backing |
| `observability` | 2 | OpenSearch + scanner — observability backbone for any lab |
| `cbom-pipeline` | 4 | Full CBOM pipeline — two CAs + scanner + observe |
| `sql-cert-labs` | 6 | SQL Server cert-management lessons (two-tier AD CS + SQL 2022) |
| `pqc-linux` | 6 | PQC migration demo, Linux-only |
| `pqc-full` | 13 | PQC migration including Windows AD CS |
| `pqc-adcs-two-tier` | 7 | Parallel ML-DSA AD CS hierarchy alongside the classical two-tier |
| `full` | 18 | Every always-on VM (the 2 PQC-only AD CS VMs ship in the `pqc-*` profiles; 20 VMs defined in total) |

Custom profile: drop a YAML into `vagrant/profiles/`, then `LAB_PROFILE=my-lab ./up.sh`:

```yaml
name: my-lab
description: Custom lab — observability + EJBCA only
components:
  - observe1
  - ejbca1
resources:
  observe1:
    memory: 4096
    cpus: 2
```

## VM Layout

The lab defines a **20-VM superset** — the Windows AD CS core (classical *and* a parallel ML-DSA PQC hierarchy) plus a Linux/Docker fleet for EJBCA, step-ca, Ory Hydra, OpenSearch, and CBOM scanning. `LAB_PROFILE` selects the subset that builds.

- **Authoritative VM inventory** (name, IP, OS, role): [ARCHITECTURE.md → VM inventory](ARCHITECTURE.md#vm-inventory-full-superset--20-vms-defined) — CI-verified against `vagrant/topology.yml`, the single machine source of truth.
- **Topology variants**: [ARCHITECTURE.md → Topology variants](ARCHITECTURE.md#topology-variants).
- **Which VMs each profile builds**: [vagrant/docs/lab-topologies.md](vagrant/docs/lab-topologies.md).

## Optional VMs

These have `autostart: false` — launch explicitly with `vagrant up <name>`.

- **manage1** — Server 2025 management workstation with full RSAT (AD, DNS, CA, GPO); `vagrant rdp manage1`. RSAT installs via `Install-WindowsFeature` from Server 2025's on-disk WinSxS in ~30 s — no external FoD source needed.
- **tomcat1** — Server 2022 with Temurin 17 + Tomcat 10.1 (~10 min). Manager: `http://192.168.56.60:8080`.
- **wsus1** — Windows update caching for all lab VMs (~15 min + sync); dedicated 200GB data disk (`WSUS_CONTENT_DISK_GB` in `config.rb`).
- **ejbca1** — EJBCA CE on Ubuntu/Docker, independent hierarchy (~5 min). Admin UI: `https://192.168.56.50:8443/ejbca/adminweb/` (client-cert auth). Publish root to AD: `vagrant provision dc1 --provision-with ejbca-trust`.
- **stepca1** — ACME-native step-ca on Ubuntu/Docker (~3 min). Endpoint: `https://192.168.56.51:9000/acme/acme/directory`. Publish root to AD: `vagrant provision dc1 --provision-with stepca-trust`.
- **hydra1** — Ory Hydra OAuth 2.0/OIDC with LDAP auth against DC1 (~5 min). Ports: 4444 (public), 4445 (admin), 3000 (consent app).
- **dc2** — secondary domain controller for AD replication testing.

## Project Structure

```
straylight/
├── scripts/
│   └── install-wizard.sh       # Single entry point — prereqs + config + deploy
├── vagrant/
│   ├── Vagrantfile             # Unified Vagrantfile (all topologies)
│   ├── config.rb               # Shared lab configuration
│   ├── up.sh                   # Orchestrated parallel build
│   ├── ansible/
│   │   ├── playbooks/          # Per-VM playbooks
│   │   ├── roles/              # 69 reusable roles — see roles/README.md
│   │   └── requirements.yml    # Ansible Galaxy collections
│   ├── scripts/
│   │   ├── lib/profile-helper.sh  # Shared LAB_PROFILE resolver (bash → Ruby)
│   │   ├── checks/                # Per-VM validate.sh assertions
│   │   ├── render-inventory.sh    # Regenerate ansible/inventory/<profile>/{static,pqc}.ini
│   │   └── validate.sh            # Post-build health check (profile-aware)
│   ├── lib/lab_profile.rb      # Vagrantfile profile resolver (Ruby)
│   └── profiles/               # Lab profile YAMLs
└── packer/                     # Custom base images (optional)
```

## Configuration

Edit `vagrant/config.rb`:

```ruby
LAB_DOMAIN     = "yourlab.local"    # AD domain name
LAB_NETBIOS    = "YOURLAB"          # NetBIOS name
LAB_NETWORK    = "192.168.56"       # IP range (VirtualBox host-only)
ADMIN_PASSWORD = "TenTowns00!"      # Change before deployment
```

CA names, validity periods, and URLs live in `PKI_CONFIG` in the same file.

**Windows Server version** (2022/2025, default 2025):

```bash
export WIN_SERVER_VERSION=2022
vagrant up
```

**Multiple labs simultaneously** — profiles already get separate dotfiles and VBox prefixes, and each lab auto-allocates its own free /24 from the `192.168.56` base; give a second lab its own identity by overriding the domain (set `LAB_NETWORK` only to pin a specific subnet):

```bash
LAB_DOMAIN=testlab.local LAB_NETBIOS=TESTLAB \
  LAB_PROFILE=ad-cs-one-tier bash up.sh
```

**Take the root CA offline** (two-tier): `vagrant halt rootca`.

## Default Credentials

| Account | Password | Notes |
|---------|----------|-------|
| Administrator | TenTowns00! | Domain admin |
| vagrant | vagrant | VM console/WinRM |
| svc-ndes | SvcPKI00! | NDES service account |
| svc-cep | SvcPKI00! | CEP service account |

## URLs (After Deployment)

| Service | URL |
|---------|-----|
| Web Enrollment (one-tier) | http://ca1.yourlab.local/certsrv |
| Web Enrollment (two-tier) | http://issueca.yourlab.local/certsrv |
| NDES (SCEP) | http://ca1.yourlab.local/certsrv/mscep/mscep.dll |
| CRL Distribution (classical) | http://pki.yourlab.local/crl/ |
| AIA (classical) | http://pki.yourlab.local/aia/ |
| CRL Distribution (ML-DSA hierarchy) | http://pki.yourlab.local/crl/pqc/ |
| AIA (ML-DSA hierarchy) | http://pki.yourlab.local/aia/pqc/ |
| EJBCA Admin | https://192.168.56.50:8443/ejbca/adminweb/ |
| step-ca ACME | https://192.168.56.51:9000/acme/acme/directory |
| Tomcat | http://192.168.56.60:8080 |
| Hydra (public) | http://192.168.56.52:4444 |
| Hydra consent | http://192.168.56.52:3000 |

## Evaluation Licenses

The lab uses Windows Server Evaluation licenses: 180 days initial, extendable via `slmgr /rearm` up to 6 times (~3 years). Rebuild from scratch when they expire.

## Known Limitations

- **AD CS native PQC** ships in full: a parallel ML-DSA hierarchy (`pqc-adcs-two-tier`) with `rootca-pqc` (offline ML-DSA-87 root) + `issueca-pqc` (enterprise ML-DSA-65 sub-CA), gated on KB5087539 / Server 2025. AD CS issues both ML-DSA CA certs and ML-DSA-65 leaf certs (via `cert_templates_pqc`). The EJBCA-Chimera + GPO trust path remains as the cross-CA comparison.
- **GnuPG ML-DSA signing** is pending GnuPG 2.6.x; Kyber-768 encryption works and ships in the demo.
- **OpenSSL 3.5 TLS 1.3 `-Verify 1`** is permissive (upstream design); mTLS verification asserts a positive log signal.

Full context: [vagrant/docs/pqc-demo-runbook.md → Known Limitations](vagrant/docs/pqc-demo-runbook.md#known-limitations-read-this-first). Component status: [tomcat-pqc-status.md](vagrant/docs/tomcat-pqc-status.md), [gnupg-pqc-status.md](vagrant/docs/gnupg-pqc-status.md).

## Provenance

Straylight has been developed privately since April 2025. The public repository is a curated snapshot line of that work: history before its first public commit remains in the private development archive, and the dated release history in [CHANGELOG.md](CHANGELOG.md) is the authoritative timeline. Content still being hands-on verified (most of the walkthrough catalog) stays in the archive and lands here as it passes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [.github/copilot-instructions.md](.github/copilot-instructions.md). Code of conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Security issues: [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
