# Copilot Instructions for Straylight PKI Lab

## Project Overview

Vagrant-based PKI lab for testing Windows AD CS deployments — automated one-tier and two-tier topologies with full enterprise features — plus optional EJBCA and step-ca VMs for open-source PKI comparison.

## Architecture

- **Host**: Ubuntu Desktop with VirtualBox + Vagrant + Ansible
- **VM source of truth**: `vagrant/topology.yml` — the single AUTHORITATIVE machine table; every consumer (Vagrantfile/Ruby, bash scripts, Ansible inventory) derives VM identity, IPs, groups, and dependency ordering from it. Do NOT restate VM facts elsewhere. `ARCHITECTURE.md` is the authoritative human inventory, CI-checked against `topology.yml` by `vagrant/test/doc_inventory_test.rb` — link there, never restate the VM table.
- **Topology selection**: `LAB_PROFILE` against `vagrant/profiles/*.yml` (14 profiles; single `vagrant/Vagrantfile`). Topology is derived from a profile's component list, not a flag — the old `ADCS_TOPOLOGY`/`ADCS-TOPOLOGY` env var was removed and is hard-rejected by the resolver.
- **Shared config**: `vagrant/config.rb` (domain, IPs, credentials, PKI settings); `.env` parsed by the profile resolver
- **Provisioning**: Ansible playbooks and roles in `vagrant/ansible/` (70 roles; see `vagrant/ansible/roles/README.md`); PowerShell helpers in `vagrant/scripts/windows/*.ps1` used by some roles

## Key Files

| File | Purpose |
|------|---------|
| `vagrant/topology.yml` | **Single AUTHORITATIVE VM table** — VM identity, IPs, groups, `depends_on`/readiness gates |
| `ARCHITECTURE.md` | Authoritative human-readable VM inventory + data flow, CI-checked against `topology.yml` |
| `docs/architecture-evolution.md` | How/why the architecture changed over the project's history |
| `vagrant/config.rb` | Central configuration (domain, IPs, passwords, VM resources) |
| `vagrant/Vagrantfile` | Single profile-aware Vagrantfile — VM definitions, Ansible provisioner config, host_vars |
| `vagrant/profiles/*.yml` | Lab profile definitions (component list per profile) |
| `vagrant/ansible/playbooks/` | Flat per-VM playbooks (no one-tier/two-tier subdirs); `ca.yml` dispatches on `ca_type` |
| `vagrant/ansible/roles/README.md` | Role catalog + the canonical WinRM identity model (C11) |
| `vagrant/ansible/roles/{common,common_linux}/` | Windows baseline (DNS fix, NAT adapter cleanup); Linux baseline (Docker host setup) |
| `vagrant/ansible/roles/{domain_controller,secondary_controller,domain_join}/` | AD DS forest creation (`microsoft.ad.domain`); DC2 promotion (`microsoft.ad.domain_controller`); domain membership (`microsoft.ad.membership`) |
| `vagrant/ansible/roles/enterprise_ca/` | Enterprise (one-tier / issuing) CA install (scheduled task pattern) |
| `vagrant/ansible/roles/{standalone_ca,subordinate_ca}/` | Standalone Root CA; Subordinate/Issuing CA — classical OR PQC selected by `ca_crypto_provider` (C4) |
| `vagrant/ansible/roles/publish_ca_artifacts/` | Unified CA cert/CRL publication to WEB1 (replaces the removed `publish_root_ca`) |
| `vagrant/ansible/roles/ca_crl_republish/` | Scheduled CRL republish on online issuing CAs (C10) |
| `vagrant/ansible/roles/win_scheduled_task/` | Shared scheduled-task create/run/poll/read-back/cleanup helper (C11) |
| `vagrant/ansible/roles/web_server/` | IIS for CRL/AIA distribution (classical + `/crl/pqc`, `/aia/pqc` for the PQC hierarchy) |
| `vagrant/ansible/roles/ca_services/` | NDES, CEP/CES, Web Enrollment |
| `vagrant/ansible/roles/cert_templates/` | Custom certificate templates |
| `vagrant/ansible/roles/client/` | Client autoenrollment config |
| `vagrant/ansible/roles/manage/` | RSAT tools install (scheduled task pattern) |
| `vagrant/ansible/roles/wsus_server/` | WSUS with data disk, GPO, DNS |
| `vagrant/ansible/roles/{ejbca,stepca}/` | EJBCA CE on Docker; step-ca on Docker |
| `vagrant/ansible/roles/observe_timer/` | Generalized systemd timer + `ExecStartPost` ingest pattern (C7) |
| `vagrant/ansible/requirements.yml` | Ansible Galaxy collections |
| `vagrant/scripts/validate.sh` | ~180-line profile-aware orchestrator (sources the harness + per-VM checks) |
| `vagrant/scripts/lib/validate-harness.sh` | Validate harness core — `record_result`, `launch_check`, the runner (C9) |
| `vagrant/scripts/checks/<vm>.sh` | Per-VM assertions (`register_checks_<vm>()`); `checks/common.sh` holds shared snippets |
| `vagrant/scripts/lib/pqc-verify/` | Shared PQC probes consumed by both `validate.sh` and `pqc-migrate` (C9) |
| `vagrant/cbom-toolkit/schema/cbom_envelope.json` | Versioned CBOM envelope schema — single field vocabulary, generates the OpenSearch mapping (C7) |

## Conventions

### Ansible
- `gather_facts: false` in all Windows playbooks (Windows fact gathering is slow/unnecessary)
- Pre-domain feature installs go in playbooks (not roles) to preserve parallel overlap with DC1
- Scheduled task pattern for operations requiring elevation/AD double-hop; create/run/poll/read-back/cleanup mechanics are centralized in the `win_scheduled_task` role. The WinRM identity model (WinRM session user vs SYSTEM vs explicit domain-admin) is documented canonically in `vagrant/ansible/roles/README.md` — link there, don't re-derive it in comments
- WinRM Basic auth via `host_vars` in the Vagrantfile (`ansible_winrm_transport: basic`); Linux VMs use an `ansible_connection: ssh` override
- Required collections: `microsoft.ad`, `ansible.windows`, `community.windows`, `community.docker`
- `microsoft.ad.domain` (DC1) uses `log_path`; `microsoft.ad.domain_controller` (DC2) uses `domain_log_path`

### Vagrant
- Windows guests use the WinRM communicator (not SSH); Linux VMs override with `communicator = "ssh"`
- Private network: `192.168.56.0/24` (VirtualBox host-only)
- Box images: `gusztavvargadr/windows-server-2022-standard-core` (Server Core) and `gusztavvargadr/windows-11` (clients)
- `up.sh` orchestrates parallel builds (DC1 first, then remaining VMs with staggered starts)
- Optional VMs use `autostart: false`

### AD CS Specifics
- CDP/AIA use HTTP URLs (no LDAP publishing) for lab simplicity
- CAPolicy.inf is created before `Install-AdcsCertificationAuthority`
- Two-tier: Root CA is standalone (workgroup), Issuing CA is enterprise (domain-joined)
- Classical and PQC (ML-DSA) CA hierarchies share the `standalone_ca`/`subordinate_ca` roles, selected by `ca_crypto_provider`. The PQC hierarchy (`rootca-pqc`/`issueca-pqc`) bakes a separate `/crl/pqc` + `/aia/pqc` CDP/AIA namespace into issued certs so revocation/CRL state never crosses hierarchies (C10)
- CRL republish on online issuing CAs is automated via the `ca_crl_republish` role
- Service accounts: `svc-ndes`, `svc-cep`, `svc-ces` in `OU=Service Accounts,OU=PKI`

## Common Tasks

### Adding a new VM
1. Add it to `vagrant/topology.yml` (octet, os, box, groups, `depends_on`, optional `requires_ready`/`provides`) — the Vagrantfile and inventory derive from it
2. Add it to the relevant profile(s) under `vagrant/profiles/*.yml`
3. Create a flat playbook `vagrant/ansible/playbooks/<vm>.yml`; create or reuse roles in `vagrant/ansible/roles/`
4. Add per-VM assertions in `vagrant/scripts/checks/<vm>.sh` and update the `ARCHITECTURE.md` inventory (`doc_inventory_test.rb` enforces it)

### Modifying CA configuration
1. Edit `PKI_CONFIG` in `config.rb` for names/URLs
2. Update the CAPolicy.inf template in the relevant Ansible role if needed
3. CDP/AIA URLs follow the pattern `http://pki.{domain}/{crl,aia}/`

### Adding new AD CS features
1. Install the Windows feature via `ansible.windows.win_feature`
2. Configure the service via `ansible.windows.win_powershell` (scheduled task for SYSTEM elevation)
3. Add to the `ca_services` or `enterprise_ca` role

### Re-running provisioning
```bash
# Re-provision a single VM (idempotent)
vagrant provision <vm>

# Run a named provisioner (e.g., trust publication)
vagrant provision dc1 --provision-with ejbca-trust
```

## Timing Budgets

Many roles use retry loops or scheduled-task polling to wait for asynchronous operations. Keep timeouts generous — the lab must work on slow hardware and during parallel builds where VMs compete for I/O.

### Scheduled Task Waits (PowerShell `$maxWait` loops)

These poll `schtasks /query` every N seconds until the task reaches "Ready" state.

| Role | Task | Timeout | Poll interval | Notes |
|------|------|---------|---------------|-------|
| `domain_controller` | AD DS operational after reboot | 10 min | 15s | Inner loop; also has 3 Ansible retries |
| `enterprise_ca` | CA install | 10 min | 5s | |
| `subordinate_ca` | Parent CA ping (`certutil -ping`) | 10 min | 20s | Inside scheduled task (DCOM auth required) |
| `subordinate_ca` | CRL distribution point reachable | 10 min | 20s | Inside scheduled task; parallel build bottleneck |
| `subordinate_ca` | Full CA install task | 15 min | 5s | Covers parent wait + install |
| `publish_ca_artifacts` | Publish root cert to AD / WEB1 | 2 min | 5s | (replaces removed `publish_root_ca`) |
| `ca_services` | NDES install; CEP/CES install | 10 min | 5s | |
| `manage` | RSAT install | 60 min | 30s | Windows Update fallback is very slow |
| `wsus_server` | Disk init | 2 min | 5s | |
| `wsus_server` | `wsusutil postinstall` (WID) | 10 min | 10s | |
| `wsus_server` | Catalog sync (product list) | 30 min | 30s | Polls for "Windows 11" in catalog |

### Ansible Retry Loops (`retries:` / `delay:`)

These retry an entire Ansible task on failure.

| Role | What it waits for | Retries | Delay | Total |
|------|-------------------|---------|-------|-------|
| `domain_join`, `secondary_controller` | AD DS LDAP ready (`nltest`) | 45 | 20s | 15 min |
| `domain_join` | Domain join itself | 3 | 30s | 1.5 min |
| `client` | Root CA cert in trusted store | 30 | 20s | 10 min |
| `enterprise_ca`, `subordinate_ca`, `standalone_ca` | CertSvc service running | 12 | 10s | 2 min |
| `wsus_server` | WsusService running | 12 | 10s | 2 min |
| `publish_ca_artifacts` | WEB1 SMB share reachable | 30 | 10s | 5 min |
| `ejbca`, `stepca` | Container ready | 30 | 10s | 5 min |
| `ejbca_ad_trust`, `stepca_ad_trust` | Cert download from EJBCA / step-ca | 6 | 10s | 1 min |

### Global Timeouts

| Setting | Value | Location |
|---------|-------|----------|
| WinRM operation timeout | 10 min | `group_vars/all.yml` (30 min for `manage1` playbook) |
| WinRM read timeout | 11 min | `group_vars/all.yml` (31 min for `manage1` playbook) |
| Ansible connection timeout | 60s | `ansible.cfg` |
| Ansible command timeout | 30 min | `ansible.cfg` (persistent connection) |
| Reboot timeout (all modules) | 10 min | `microsoft.ad.domain`, `microsoft.ad.membership` |

## Debugging

```bash
# Check VM status
vagrant status

# Run post-build health checks (profile-aware; PASS/FAIL/SKIP).
# validate.sh is a thin orchestrator over scripts/lib/validate-harness.sh +
# per-VM scripts/checks/<vm>.sh — add assertions in the matching checks/<vm>.sh,
# not in validate.sh itself.
bash vagrant/scripts/validate.sh

# View provisioning output
vagrant provision <vm> --debug

# SSH/WinRM into VM
vagrant ssh <vm>
vagrant winrm <vm> -c "command"

# Check Windows event logs on CA
Get-WinEvent -LogName "Application" -MaxEvents 50 | Where-Object {$_.ProviderName -like "*Cert*"}
```

## Testing Certificates

```powershell
# On CLIENT1 - trigger autoenrollment
certutil -pulse
gpupdate /force

# View enrolled certs
certutil -store My

# Test CRL access
certutil -URL http://pki.yourlab.local/crl/
```
