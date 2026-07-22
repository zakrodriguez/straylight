# Straylight Lab — Getting Started

A Vagrant-based Windows PKI lab with CBOM (Cryptographic Bill of Materials) scanning, OpenSearch observability, and PQC readiness scoring.

Architecture (data flow, topology variants, authoritative VM inventory, PQC surface): [../ARCHITECTURE.md](../ARCHITECTURE.md). Rationale — the 2026-06 C1–C12 remediation: [../docs/architecture-evolution.md](../docs/architecture-evolution.md).

## Prerequisites

- **VirtualBox** 7.x
- **Vagrant** 2.4+ with `vagrant-vbguest` plugin
- **Ansible** 2.15+ (runs from Linux/macOS host)
- **Python** 3.10+ (for CBOM toolkit)
- ~80 GB free disk, 32 GB RAM recommended

## Quick Start

### Option A: Install Wizard (recommended for first-time setup)

```bash
git clone https://github.com/zakrodriguez/straylight.git
cd straylight
bash scripts/install-wizard.sh
```

The wizard checks and installs prerequisites (VirtualBox, Vagrant, Ansible, Python, etc.), asks for domain and lab profile (topology is determined by profile), writes `vagrant/.env`, and optionally starts the deployment.

### Option B: Manual Setup (if prereqs already installed)

```bash
git clone https://github.com/zakrodriguez/straylight.git
cd straylight/vagrant

# Install Ansible collections
ansible-galaxy collection install -r ansible/requirements.yml

# Populate the local software cache (~320 MB, one-time)
# Skips installers/tarballs that VMs would otherwise fetch from
# github.com / elastic.co / gnupg.org / go.dev during provisioning.
bash scripts/cache-software.sh

# Build the core lab (~45-90 min depending on profile)
bash up.sh

# (Optional) Add observability stack
LAB_COMPONENTS=observe1 bash up.sh
```

### Key Scripts

| Script | Purpose |
|--------|---------|
| `bash scripts/install-wizard.sh` | First-time setup: prereqs + config + deploy |
| `bash scripts/cache-software.sh` | Pre-stage installers/tarballs into `vagrant/resources/software/` (run once before first cold-build) |
| `bash up.sh` | Build core lab (DC1 first, then rest in parallel) |
| `bash up.sh --all` | Alias for `LAB_PROFILE=full` — builds every VM (18) |
| `bash scripts/start-vms.sh` | Start all existing VMs (no provisioning) |
| `bash scripts/stop-vms.sh` | Gracefully stop all running VMs |
| `bash logging.sh --status` | Check logging agent status across VMs |
| `bash scripts/validate.sh` | Run health checks on all running VMs |
| `bash scripts/cbom-pipeline.sh` | Full CBOM scan → validate → diff → ingest → score |

## Lab Topology

Topology is a property of the active `LAB_PROFILE`: `ad-cs-one-tier`, `ad-cs-two-tier`, or any other profile in `vagrant/profiles/` (`bash up.sh --list-profiles` for the full catalog).

The authoritative **VM inventory** (names, IPs, OS, roles) is the table in [../ARCHITECTURE.md](../ARCHITECTURE.md#vm-inventory-full-superset--20-vms-defined), derived from `vagrant/topology.yml` and CI-checked against it. The active profile determines which VMs a run starts (see **Lab Profiles** below); core profiles autostart their VMs, optional VMs are `autostart: false`.

### APPS1 Services

| Service | URL | Credentials |
|---------|-----|-------------|
| Keycloak | http://192.168.56.55:8080 | admin / TenTowns00! |
| Vault | http://192.168.56.55:8200 | root token: `straylight-root-token` |
| NiFi | https://192.168.56.55:8444/nifi/ | admin / TenTowns00! |
| Gitea | http://192.168.56.55:3000 | (first-run setup wizard) |
| MinIO | http://192.168.56.55:9011 | admin / TenTowns00! |

## Credentials

| Account | Password |
|---------|----------|
| Domain admin | TenTowns00! |
| Safe mode | TenTowns00! |
| Service account | SvcPKI00! |
| All app services | TenTowns00! |

## CBOM Toolkit

Python tools live in `cbom-toolkit/python/`, PowerShell in `cbom-toolkit/powershell/`.

### Pipeline (end-to-end)

```bash
# Full pipeline: export certs -> scan -> deduplicate -> validate -> diff -> ingest -> score
bash scripts/cbom-pipeline.sh

# Scan only (skip cert export, use existing data)
bash scripts/cbom-pipeline.sh --scan-only

# Skip OpenSearch ingest
bash scripts/cbom-pipeline.sh --no-ingest

# Skip PQC scoring
bash scripts/cbom-pipeline.sh --no-score

# Use a specific scanner
bash scripts/cbom-pipeline.sh --scanner theia
```

Output goes to `cbom-output/`. Baselines are stored in `cbom-toolkit/baselines/`.

### Individual Tools

**Validate** a CBOM for CycloneDX 1.6 crypto-correctness:

```bash
python3 cbom-toolkit/python/cbom_validate.py cbom-output/scan.json
```

**Diff** two CBOMs (baseline vs. current):

```bash
python3 cbom-toolkit/python/cbom_diff.py baseline.json current.json
```

**Ingest** CBOM components into OpenSearch:

```bash
python3 cbom-toolkit/python/cbom_ingest.py cbom-output/scan.json --scanner cbomkit-theia
python3 cbom-toolkit/python/cbom_ingest.py scan.json --scanner cbomkit-theia --dry-run
```

**Score** PQC readiness per VM:

```bash
python3 cbom-toolkit/python/cbom_score.py cbom-output/scan.json
```

### OpenSearch Setup (one-time)

> **Skip if role-managed.** The `opensearch_stack` Ansible role already installs the dashboards + index templates when OBSERVE1 is provisioned. Run the commands below only if you stood up OpenSearch outside the normal Vagrant flow, or the role didn't run.

After OBSERVE1 is up, create the alert rules and dashboards:

```bash
python3 cbom-toolkit/python/cbom_alerts.py \
  --opensearch-url http://192.168.56.53:9200

python3 cbom-toolkit/python/osd_dashboards.py \
  --opensearch-url http://192.168.56.53:9200
```

This creates 5 alert rules (private key exposure, weak algorithms, small RSA keys, expiring certs, new scans) and 7 dashboards (crypto posture overview, certificate lifecycle, drift detection, PQC readiness scorecard, certificate expiry & health, VM security posture, cross-protocol PQC posture).

To tear them down:

```bash
python3 cbom-toolkit/python/cbom_alerts.py --delete --opensearch-url http://192.168.56.53:9200
python3 cbom-toolkit/python/osd_dashboards.py --delete --opensearch-url http://192.168.56.53:9200
```

## Logging Stack

Ships events from all VMs to OpenSearch:

- **Windows VMs**: Winlogbeat (EventLog, Sysmon, PowerShell ScriptBlock, DNS Analytical, AD CS audit)
- **Linux VMs**: Filebeat (Docker container logs, syslog)
- **Toggle on/off**: `bash logging.sh --enable all` / `--disable all` / `--status`

Control individual services with env vars: `LOGGING_ENABLED`, `WINLOGBEAT_ENABLED`, `FILEBEAT_ENABLED`, `SYSMON_ENABLED`.

## Build Scripts

```bash
# Full build with parallelization (DC1 first, then rest in parallel)
bash up.sh

# All VMs including optional
bash up.sh --all

# Custom VM list
bash up.sh --file my-vms.txt

# Snapshot after build
bash up.sh --save-snap dc1,ca1,web1

# Restore from snapshot (fast rebuild)
bash up.sh --restore-snap dc1,ca1,web1

# Rebuild specific VMs
bash up.sh --rebuild ca1
```

### Lab Profiles

Set via the install wizard or `vagrant/.env`:

| Profile | VMs | Use Case |
|---------|-----|----------|
| **core** | DC1, CA1, WEB1, MANAGE1 | Quick PKI testing |
| **ad-cs-one-tier** | DC1, CA1, WEB1, MANAGE1 | One-tier ADCS (CA1 = root + issuer) |
| **ad-cs-two-tier** | DC1, ROOTCA, ISSUECA, WEB1, MANAGE1 | Two-tier ADCS (offline root + issuing) |
| **ad-cs-minimal** | DC1, CA1, WEB1 | Minimal one-tier PKI, no workstation |
| **pqc-adcs-two-tier** | DC1, ROOTCA, ISSUECA, ROOTCA-PQC, ISSUECA-PQC, WEB1, MANAGE1 (7 VMs) | AD CS PQC test-bed: classical + ML-DSA CA hierarchies |
| **observability** | OBSERVE1, SCANNER1 (2 VMs, no core) | OpenSearch + dashboards demo, no PKI |
| **cbom-pipeline** | EJBCA1, STEPCA1, OBSERVE1, SCANNER1 (4 VMs) | Minimum CBOM scan → ingest pipeline |
| **ejbca-only** | EJBCA1, SCANNER1 | EJBCA CE standalone + scanner |
| **stepca-only** | STEPCA1, ACME1, OBSERVE1 | Smallstep step-ca + ACME sandbox |
| **oauth-oidc** | HYDRA1, STEPCA1, OBSERVE1 | Ory Hydra OAuth 2.0/OIDC sandbox |
| **sql-cert-labs** | DC1, ROOTCA, ISSUECA, WEB1, MANAGE1, SQLHOST1 (6 VMs) | Two-tier ADCS + SQL Server 2022 cert binding lab |
| **pqc-linux** | OBSERVE1, EJBCA1, STEPCA1, HYDRA1, SCANNER1, ACME1 (6 VMs) | Linux/PQC crypto comparison stack |
| **pqc-full** | DC1, ROOTCA, ISSUECA, ROOTCA-PQC, ISSUECA-PQC, WEB1, MANAGE1, EJBCA1, STEPCA1, HYDRA1, OBSERVE1, SCANNER1, ACME1 (13 VMs) | End-to-end PQC migration demo |
| **full** | 18 VMs (every always-on VM; the PQC-only `ROOTCA-PQC`/`ISSUECA-PQC` ship in `pqc-adcs-two-tier`/`pqc-full` instead) | Complete lab |

```bash
# Create .env manually (alternative to wizard)
cat > vagrant/.env << 'EOF'
LAB_PROFILE=cbom-pipeline
EOF
cd vagrant && bash up.sh
```

To start/stop VMs without re-provisioning (shell helpers source the profile so VAGRANT_DOTFILE_PATH is set correctly):

```bash
LAB_PROFILE=ad-cs-two-tier bash up.sh                  # Build / resume
LAB_PROFILE=ad-cs-two-tier bash provision.sh apps1     # Re-provision one VM
LAB_PROFILE=ad-cs-two-tier bash snap.sh save dc1 ca1   # Snapshot
```

For ad-hoc `vagrant` invocations (not via the wrappers), set both `LAB_PROFILE` and `VAGRANT_DOTFILE_PATH` since Vagrant chooses its dotfile path before parsing the Vagrantfile:

```bash
VAGRANT_DOTFILE_PATH=.vagrant-ad-cs-two-tier LAB_PROFILE=ad-cs-two-tier \
  vagrant halt apps1
```

## Topology Selection

```bash
# One-tier (CA1 = root + issuing)
LAB_PROFILE=ad-cs-one-tier bash up.sh

# Two-tier: ROOTCA (offline) + ISSUECA (enterprise subordinate)
LAB_PROFILE=ad-cs-two-tier bash up.sh
```

Each profile gets its own `.vagrant-<name>/` dotfile so state stays separate.

## Troubleshooting

**VM won't provision**: `LAB_PROFILE=<name> bash provision.sh <vm>` to re-run idempotently.

**WinRM timeout**: Windows VMs use Basic auth. Check with `LAB_PROFILE=<name> bash -c 'source scripts/lib/profile-helper.sh; vagrant winrm -c "hostname" <vm>'`.

**OpenSearch not receiving data**: Verify OpenSearch is running on OBSERVE1 (`curl http://192.168.56.53:9200/_cluster/health`). Winlogbeat/Filebeat output directly to port 9200.

**NiFi slow to start**: NiFi takes 2-5 minutes for JVM startup. The Ansible role retries for up to 10 minutes.

**Domain join fails**: DC1 must finish AD DS promotion first. The join role retries for 15 minutes with `nltest` checks.

## OpenSearch Dashboards (Log Search)

Ad-hoc log search and investigation:

- **URL**: http://192.168.56.53:5601
- **Discover**: hamburger menu → "Discover" (the Kibana-style log explorer)
- **Index pattern**: `logs-*` is pre-configured with `@timestamp` as the time field
- No login required (security plugin disabled for lab use)

All data (CBOM, Sysmon, Windows Security, PowerShell, AD CS, Linux/Docker, DNS) is searchable here with click-to-filter, field breakdowns, and drill-in.

## Known Limitations

Before demoing PQC to an audience, skim the Known Limitations section in [docs/pqc-demo-runbook.md](docs/pqc-demo-runbook.md#known-limitations-read-this-first). The three big ones:

- Microsoft AD CS cannot natively issue ML-DSA certs as of Server 2025 (May 2026 patch level) — the lab routes around via EJBCA-Chimera.
- GnuPG 2.5.x has Kyber encryption but no ML-DSA signing yet.
- OpenSSL 3.5 TLS 1.3 `-Verify 1` is permissive — mTLS demo asserts positive server-log signal rather than handshake failure.

Component-by-component status: [tomcat-pqc-status.md](docs/tomcat-pqc-status.md), [gnupg-pqc-status.md](docs/gnupg-pqc-status.md).
