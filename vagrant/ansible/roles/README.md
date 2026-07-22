# Ansible Roles

Reusable Ansible roles for straylight, organized by capability area. Each role is invoked from one or more playbooks in `../playbooks/`.

## Conventions

- **Windows roles** use `gather_facts: false` in their playbooks (Windows fact gathering is slow and rarely needed).
- **Linux roles** use `ansible_connection: ssh` set in host_vars.
- **Windows identity model**: see [Windows identity model](#windows-identity-model) — the canonical reference. Scheduled-task wrappers are the standard elevation mechanism.
- **Idempotency gates**: every role's `main.yml` starts with a state check that short-circuits if the work is already done.
- **Required collections** are pinned in `../requirements.yml`. CI installs them automatically.

## Windows identity model

Every Windows task runs under one of three security contexts. Picking the wrong one is the most common source of "works manually, fails under Ansible" bugs here: the WinRM network logon strips the credentials needed for downstream AD / DPAPI / service operations (the "double-hop" problem). This section is the single source of truth; roles link here rather than re-deriving it in comments.

| Context | How it's selected | When to use it |
|---|---|---|
| **WinRM session user** (`vagrant`, a local admin) — the default | No wrapper; the task just runs | Local, non-AD work that doesn't cross a second hop: file ops on the box, registry, local services, `win_*` modules that touch only the local machine. This is the WinRM network logon, so it **cannot** present credentials to a *second* remote system (AD LDAP writes, remote CA RPC, network shares) — that's the double-hop limit. |
| **`SYSTEM`** via a scheduled task (`New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest`, then `Register-ScheduledTask` / run / poll / read-back) | Wrap the PowerShell in a scheduled task whose principal is `SYSTEM` | Local-machine operations that need full local elevation but authenticate to AD as the **computer account** — machine-cert autoenrollment, CRL republish, SQL Server install. SYSTEM presents the machine's Kerberos identity over the network, which satisfies the double-hop for *machine-scoped* AD operations. Canonical: `machine_cert`, `pqc_machine_cert`, `ca_crl_republish`, `sql_server`, `cms_lab_{linux,windows}/tasks/certs.yml`. |
| **Explicit domain admin** via a scheduled task (`schtasks /create … /ru "{{ lab_netbios }}\Administrator" /rp '{{ admin_password }}' /rl highest`, then run / poll / delete) | Wrap the PowerShell in a scheduled task whose `/ru` is a named domain admin and `/rp` supplies the password | Operations that need a **user** Kerberos TGT to act on AD as a privileged human: CA role install, certificate-template publishing + ACLs, AD config-NC writes. SYSTEM (computer account) lacks the rights; the WinRM session user can't double-hop to AD. Canonical: `enterprise_ca`, `subordinate_ca`, `ca_services`, `cert_templates`, `cert_templates_pqc`, `ejbca_ad_trust`, `stepca_ad_trust`. |

Decision shortcut:

- Does the task only touch the local box and never authenticate to a second system? → **default WinRM user**, no wrapper.
- Does it need elevation *and* authenticate to AD as the **machine**? → **SYSTEM scheduled task**.
- Does it need to act on AD as a **privileged user** (CA/template/AD-write ops)? → **explicit domain-admin scheduled task** (`/ru … /rp …`).

Both scheduled-task variants share one lifecycle — create, run, poll for `Ready`, read back a status/log sidecar file, delete the task, and scrub temp files (`/rp` writes the password into the task definition). Canonical implementations: `enterprise_ca/tasks/main.yml` (explicit domain admin) and `machine_cert/tasks/main.yml` (SYSTEM). The register/run/poll/read-back/cleanup mechanics are centralized in the **`win_scheduled_task`** role (catalog below), so call sites differ only by principal.

> Note: `become: true` appears in a few roles (`iis_chimera_demo`, `acme_client`, `cms_lab_linux`) but always on **Linux** tasks (`delegate_to` a Linux host, `become_method: sudo`). There is no `runas` become on Windows — Windows elevation goes exclusively through the scheduled-task wrappers above.

## PQC demo cert contract

The two Linux PQC TLS-listener roles (`nginx_pqc_demo`, `openssl_pqc_demo`) share one cert-supply convention (symmetric `<role>_pqc_*` var prefix) so callers can swap between them:

- The caller MUST supply the **leaf** cert + key as `<role>_pqc_cert_path` / `<role>_pqc_key_path` (full PEM paths on the target VM) — **required, no defaults**; each role asserts them with a clear `fail_msg`.
- `openssl_pqc_demo` additionally needs the **issuing + root CA PEMs** for the `s_server -CAfile` verify chain and the loopback handshake probe. By contract these live **alongside the leaf cert** (same directory) under the fixed EJBCA-PQC names, overridable as `openssl_pqc_issuing_ca_path` / `openssl_pqc_root_ca_path` / `openssl_pqc_chain_path` in that role's `defaults/main.yml`, and asserted up front rather than failing opaquely mid-run. `nginx_pqc_demo` only stages the leaf, so it has no CA-path vars.

## Core lab infrastructure

| Role | Purpose |
|---|---|
| `common` | Windows baseline — DNS, NAT adapter cleanup, PowerShell 7, common tools |
| `common_linux` | Linux baseline — apt update, base packages, timezone |
| `docker_host` | Docker CE install + dockerd config (Linux) |
| `domain_controller` | AD DS forest creation (`microsoft.ad.domain`) |
| `secondary_controller` | DC2 promotion (`microsoft.ad.domain_controller`) |
| `domain_join` | Domain membership (`microsoft.ad.membership`) with `nltest` readiness gate |
| `client` | Client autoenrollment config + Group Policy receive |
| `manage` | RSAT tool install on MANAGE1 via scheduled task |
| `host_ready` | Bounded per-capability readiness probes, gated on a host's topology `requires_ready` tags |
| `shared_folder_repair` | Re-establish the `C:\Software` → `\\vboxsvr` shared-folder symlink when the VirtualBox mount drops |
| `win_scheduled_task` | Stage the shared `Invoke-StraylightAdminScheduledTask` helper (one-shot domain-admin scheduled-task create/run/poll/delete/read-back lifecycle); dot-source via `{{ schtask_admin_init }}`. See [Windows identity model](#windows-identity-model) |

## Certificate authorities

| Role | Purpose |
|---|---|
| `standalone_ca` | Standalone offline Root CA (two-tier); RSA or ML-DSA via `ca_crypto_provider` |
| `enterprise_ca` | Enterprise Root CA (one-tier all-in-one) |
| `subordinate_ca` | Enterprise online Issuing CA (two-tier); RSA or ML-DSA via `ca_crypto_provider` |
| `ca_services` | NDES, CEP/CES, Web Enrollment on the issuing CA |
| `cert_templates` | Custom certificate template imports + ACLs |
| `cert_templates_pqc` | Publish the ML-DSA-65 leaf template on the PQC issuing CA + prove issuance on `issueca-pqc` |
| `machine_cert` | Autoenrollment trigger + machine cert verification |
| `pqc_machine_cert` | Enroll an ML-DSA-65 Server-Auth machine cert from the PQC CA via `certreq` (Server 2025 GPO autoenrollment can't yet process ML-DSA templates) |
| `publish_ca_artifacts` | Copy a CA's cert(s) + CRL(s) to WEB1's PKI$ share (AIA/CDP); shared by the root, enterprise, and issuing CAs (`publish_tag`, `publish_subdir` per caller — PQC uses the `pqc` subdir) |
| `ca_crl_republish` | Daily scheduled `certutil -CRL` + web1 republish on the online issuing CAs; keeps the HTTP CDP fresh independent of the 26-week CRL validity |

## EJBCA + PQC

| Role | Purpose |
|---|---|
| `ejbca` | EJBCA Community Edition on Docker (Linux) |
| `ejbca_pqc` | ML-DSA-65 PQC CA hierarchy in EJBCA (Root + Issuing + Chimera Root) |
| `ejbca_pqc_enroll` | Issue ML-DSA-65 leaf certs to Linux hosts |
| `ejbca_admin_bootstrap` | Initial admin user + role-template seeding via Playwright |
| `ejbca_chimera_profile` | Chimera CA + cert profile in EJBCA admin UI via Playwright |
| `ejbca_ad_trust` | Publish EJBCA root cert into AD Configuration NC for forest-wide trust |

## step-ca + OAuth

| Role | Purpose |
|---|---|
| `stepca` | Smallstep step-ca on Docker (Linux) |
| `stepca_ad_trust` | Publish step-ca root cert into AD for domain trust |
| `acme_client` | ACME client (acme.sh + step CLI) for HTTP-01 enrollment |
| `hydra` | Ory Hydra OAuth 2.0 / OIDC server with LDAP backend |

## PQC surfaces

| Role | Purpose |
|---|---|
| `openssl_35` | Build OpenSSL 3.5 from source; install at `/opt/openssl-3.5` |
| `openssl_pqc_demo` | Pure-PQC TLS listener via `openssl s_server` (ML-DSA-65 leaf) |
| `openssh_pqc` | Build OpenSSH 10 + enable ML-KEM hybrid KEX (`mlkem768x25519-sha256`) |
| `nginx_pqc_demo` | nginx with chimera cert serving (Linux side) |
| `iis_chimera_demo` | IIS binding for chimera cert (RSA + ML-DSA-65 alt-sig) on Windows |
| `gnupg_pqc` | Build GnuPG 2.5.x from source; generate Kyber-768 subkeys |
| `adcs_pqc_audit` | Layered Windows AD CS PQC capability audit (CNG / CertEnroll / ca.exe) |
| `cms_lab_linux` | Stage the Cryptographic Message Syntax (ML-DSA / ML-KEM) hands-on lab at `/opt/cms-lab/` on scanner1 |
| `cms_lab_windows` | CMS lab companion on manage1 (PowerShell + .NET tooling) at `C:\cms-lab\` |

## Observability + CBOM

| Role | Purpose |
|---|---|
| `opensearch_stack` | OpenSearch + OpenSearch Dashboards on observe1 + dashboards/index templates |
| `observe_timer` | Reusable systemd oneshot + timer + ExecStartPost ingest hook (generalized CF-timer pattern) |
| `observe_tls` | ACME-issued TLS cert on observe1:443 + auto-renewal |
| `winlogbeat` | Winlogbeat per-VM channels (DC, CA, IIS, WSUS, Sysmon) |
| `filebeat` | Filebeat on Linux VMs |
| `filebeat_iis` | Filebeat for IIS access logs |
| `windows_logging` | Advanced audit policy + PowerShell ScriptBlock logging |
| `sysmon` | Sysmon with SwiftOnSecurity config |
| `psframework` | PSFramework structured logging module setup |
| `cbom_source_repos` | Clone CBOM source repos (theia, etc.) onto scanner1 |
| `cbom_lens` | CBOM "lens" companion app (visualization shim) |
| `cloudflare_pqc` | Probe public Cloudflare edge PQC endpoints from scanner1 + feed results into the CBOM pipeline |

## Network services + lab support

| Role | Purpose |
|---|---|
| `web_server` | IIS for CRL/AIA distribution + PKI vhost |
| `wsus_server` | WSUS install + content disk + GPO + DNS |
| `windows_kb_install` | Install a single Windows hotfix / cumulative update by KB number (cache-first + SYSTEM-schtask) |
| `tomcat` | Apache Tomcat 10.1 + Eclipse Temurin 17 |
| `nifi` | Apache NiFi for CBOM ingest experiments |
| `keycloak` | Keycloak for OIDC alternative |
| `vault` | HashiCorp Vault (PKI engine demos) |
| `minio` | MinIO object store for CBOM artifact testing |
| `gitea` | Gitea for git + commit-signing demos |
| `sql_server` | SQL Server 2022 Developer on Windows Server 2025 |
| `yubihsm` | YubiHSM2 SDK + PKCS#11 install (paired with EJBCA) |
| `cipheriq` | CipherIQ demo workload |

## Desktop / cosmetic (Windows)

| Role | Purpose |
|---|---|
| `bginfo` | BgInfo on Windows VMs with per-role custom fields |
| `desktop_customize` | Taskbar pins, Start menu cleanup, registry tweaks |
| `gui_tools` | Notepad++, Nmap (with Npcap), GUI extras |
| `sysinternals` | Sysinternals Suite |
| `chocolatey` | Chocolatey package manager with local cache source |

## Where to find the playbook for each role

Roles are invoked from `../playbooks/<vm>.yml` (one playbook calls many roles; some roles run on multiple VMs). To find which playbook uses a role:

```bash
grep -rln "role: <role-name>\|- <role-name>" vagrant/ansible/playbooks/
```

## Adding a role

1. Scaffold: `mkdir -p new_role_name/{tasks,defaults,templates,handlers,files}`
2. Write `tasks/main.yml`, starting with an idempotency gate.
3. Document the role's required + optional vars in `defaults/main.yml`.
4. Add a row to the table above.
5. Wire it into at least one playbook in `../playbooks/`.
6. Run `ansible-lint roles/<role-name>/` to check.
