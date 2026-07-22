# Straylight Reference (v2.8.1)

The walkthrough labs run against the [Straylight](https://github.com/zakrodriguez/straylight)
PKI lab. This doc lists the **defaults the labs assume**, for
spot-checking a diverged local install (custom LAB_DOMAIN, alternate
profile, etc.). Aligned with **Straylight v2.8.1** (tagged 2026-07-18);
re-check when Straylight tags a new minor.

> **Lab catalog status:** the on-disk catalog currently ships only the
> `adcs-functest` module (`docs/walkthroughs/labs/`). Every other lab
> named in this document (`dns-persist-01-pebble`, `webserver-ssl-*`,
> the ESC labs, `template-flags`, `untrustedca`, `crl-offline`, the
> ACME/mTLS labs, the `pqc-*` modules, …) lives in the
> development archive and returns module-by-module as it is
> hand-verified.

> **Authoritative VM/role inventory:** the canonical VM topology and
> role inventory (69 roles) live in [`ARCHITECTURE.md`](../../ARCHITECTURE.md);
> if the two disagree, `ARCHITECTURE.md` wins. The 2026-06 remediation
> behind much of this is narrated in
> [`docs/architecture-evolution.md`](../architecture-evolution.md).

## Defaults the labs assume

| Setting | Value | Where it lives in Straylight |
|---|---|---|
| Domain | `yourlab.local` | `LAB_DOMAIN` env var; default in `vagrant/config.rb` |
| NetBIOS | `YOURLAB` | `LAB_NETBIOS` env var; default in `vagrant/config.rb` |
| Host-only network | `192.168.56.0/24` (base; **allocated per-lab dynamically**) | `topology.yml` base `192.168.56` + `vagrant/lib/lab_network.rb` (v2.2.0/#188). A solo lab still takes `.56`; concurrent labs each get the next free `/24`. Override with `LAB_NETWORK`. |
| Root CA name | `YOURLAB-Root-CA` | Derived from `LAB_NETBIOS` in `PKI_CONFIG` |
| Issuing CA name | `YOURLAB-Issuing-CA` | Derived from `LAB_NETBIOS` in `PKI_CONFIG` |
| One-tier CA name | `YOURLAB-Issuing-CA` (on `ca1`) | Derived; one-tier collapses root + issuing |
| Step-ca container CA | `Smallstep-CA` | `vagrant/ansible/inventory/group_vars/all.yml` |
| Step-ca image tag | `smallstep/step-ca:0.30.2` | same |
| Step-ca password | `stepcapass00!` | same (lab credential; do not reuse in prod) |
| Admin password | `TenTowns00!` | `ADMIN_PASSWORD` in `vagrant/config.rb` |
| Service account password | `SvcPKI00!` | `SVC_PASSWORD` in `vagrant/config.rb` |
| Windows Server default | 2025 | `WIN_SERVER_VERSION` env var |
| PowerShell version on Windows | 7.4.7 | `PWSH_VERSION` |
| Timezone | Central Standard Time | `LAB_TIMEZONE` |

With custom values (`LAB_DOMAIN=acme.test`, `LAB_NETBIOS=ACME`),
substitute when reading the labs: `yourlab.local` → `<your LAB_DOMAIN>`;
`YOURLAB-Issuing-CA` / `YOURLAB-Root-CA` / `YOURLAB\Administrator` →
the same with `<your LAB_NETBIOS>` in place of `YOURLAB`.

## VM inventory (20 VMs defined; `full` ships 18)

`full` builds 18 of the 20 defined VMs — the two PQC-only AD CS VMs
(`rootca-pqc`, `issueca-pqc`) ship only in `pqc-adcs-two-tier` /
`pqc-full`.

| VM | IP | OS | Role | Profile membership |
|---|---|---|---|---|
| `dc1` | 192.168.56.10 | Windows Server | AD DS + DNS (PDC equivalent) | most profiles |
| `dc2` | 192.168.56.11 | Windows Server | Secondary DC | `full` only |
| `rootca` | 192.168.56.20 | Windows Server | Standalone offline Root CA | `ad-cs-two-tier`, `pqc-adcs-two-tier`, `sql-cert-labs`, `pqc-full`, `full` |
| `issueca` | 192.168.56.21 | Windows Server | Enterprise Issuing CA (two-tier) | `ad-cs-two-tier`, `pqc-adcs-two-tier`, `sql-cert-labs`, `pqc-full`, `full` |
| `rootca-pqc` | 192.168.56.25 | Windows Server | Standalone offline ML-DSA-87 Root CA (parallel PQC hierarchy) | `pqc-adcs-two-tier`, `pqc-full` |
| `issueca-pqc` | 192.168.56.26 | Windows Server | Enterprise ML-DSA-65 Issuing CA (parallel PQC hierarchy) | `pqc-adcs-two-tier`, `pqc-full` |
| `ca1` | 192.168.56.22 | Windows Server | One-tier CA (root + issuing combined) | `ad-cs-one-tier`, `ad-cs-minimal`, `core`, `full` |
| `web1` | 192.168.56.30 | Windows IIS | CRL/AIA hosting + IIS | most ADCS profiles |
| `client1` | 192.168.56.100 | Windows 11 | Domain-joined client | `full`, ESC labs (parked) |
| `manage1` | 192.168.56.101 | Windows Server | Admin workstation (RSAT, RDP target) | most ADCS profiles |
| `wsus1` | 192.168.56.40 | Windows Server | WSUS for offline patching | `full` |
| `tomcat1` | 192.168.56.60 | Windows + Java + Tomcat | JKS / keystore labs | `full`, JKS-relevant |
| `sqlhost1` | 192.168.56.80 | Windows + SQL Server | SQL Server cert binding | `sql-cert-labs`, `full` |
| `ejbca1` | 192.168.56.50 | Linux + Docker | EJBCA CA + chimera CA | `ejbca-only`, `cbom-pipeline`, `pqc-linux`, `pqc-full`, `full` |
| `stepca1` | 192.168.56.51 | Linux + Docker | smallstep step-ca + ACME provisioner | `stepca-only`, `oauth-oidc`, `cbom-pipeline`, `pqc-linux`, `pqc-full`, `full`, most ACME profiles |
| `hydra1` | 192.168.56.52 | Linux + Docker | Ory Hydra OAuth/OIDC | `oauth-oidc`, `pqc-linux`, `pqc-full`, `full` |
| `observe1` | 192.168.56.53 | Linux | OpenSearch + dashboards + CBOM ingest | `observability`, `stepca-only`, `oauth-oidc`, `cbom-pipeline`, `pqc-linux`, `pqc-full`, `full` |
| `scanner1` | 192.168.56.54 | Linux + Docker | CBOM scanners + openssl 3.5 + theia | `cbom-pipeline`, `ejbca-only`, `observability`, `pqc-linux`, `pqc-full`, `full` |
| `apps1` | 192.168.56.55 | Linux + Docker | Applications-platform host (Keycloak, Vault, NiFi, Gitea, MinIO) | `full` |
| `acme1` | 192.168.56.70 | Linux + nginx + step CLI + acme.sh + certbot | Primary ACME target | `stepca-only`, `pqc-linux`, `pqc-full`, `full`, most ACME labs |

**Note:** `ca1` (`.22`, one-tier) and the two-tier pair `rootca`
(`.20`) + `issueca` (`.21`) are **alternative topologies**; only the
`full` profile ships both. IPs are solo-lab defaults on the
`.56` base; concurrent labs shift each lab's `/24` (see the host-only
network row).

## Lab profile catalog (v2.8.1)

```bash
# Discover profiles + their VM lists
cd vagrant && ./up.sh --list-profiles
./up.sh --show-profile ad-cs-two-tier
```

| Profile | VMs | Use case |
|---|---|---|
| `core` | dc1 + ca1 + web1 + manage1 | Default — minimum useful AD CS demo |
| `ad-cs-one-tier` | dc1 + ca1 + web1 + manage1 | Single-CA topology |
| `ad-cs-two-tier` | dc1 + rootca + issueca + web1 + manage1 | **Most ADCS labs target this** |
| `ad-cs-minimal` | dc1 + ca1 + web1 | ~3 GB RAM, smallest AD CS demo (web1 required for CRL/AIA publication) |
| `cbom-pipeline` | observe1 + scanner1 + ... | CBOM scanner + OpenSearch pipeline |
| `ejbca-only` | ejbca1 + scanner1 | EJBCA standalone (mTLS labs, parked; scanner1 for nmap/TLS probes) |
| `oauth-oidc` | hydra1 + ... | Ory Hydra OAuth/OIDC |
| `observability` | observe1 + ... | OpenSearch + Filebeat + Winlogbeat |
| `pqc-adcs-two-tier` | dc1 + rootca + issueca + rootca-pqc + issueca-pqc + web1 + manage1 (7 VMs) | AD CS PQC test-bed: classical two-tier + parallel ML-DSA hierarchy |
| `pqc-full` | 13 VMs incl. Windows + Linux | Pure PQC + chimera certs end-to-end (adds the ML-DSA AD CS hierarchy) |
| `pqc-linux` | Linux-only PQC subset | PQC without Windows |
| `sql-cert-labs` | dc1 + sqlhost1 + ... | SQL Server cert binding |
| `stepca-only` | stepca1 + acme1 + observe1 | Step-ca standalone |
| `full` | 18 VMs (of 20 defined) | All surfaces; ~77 GB RAM at current VM_DEFAULTS (needs a 96 GB+ host) |

## Migration from pre-v1.0 syntax

**`ADCS_TOPOLOGY=two-tier`** was removed in v1.0. Replacements:

```bash
# Old (pre-v1.0; broken in v1.0):
VAGRANT_DOTFILE_PATH=.vagrant ADCS_TOPOLOGY=two-tier vagrant up <vms>

# v1.0 — full profile build:
LAB_PROFILE=ad-cs-two-tier bash up.sh

# v1.0 — selective VM bring-up via the wrapper:
LAB_COMPONENTS=acme1,dc1,manage1,stepca1 bash up.sh

# v1.0 — raw vagrant (needs both env vars set):
VAGRANT_DOTFILE_PATH=.vagrant-ad-cs-two-tier LAB_PROFILE=ad-cs-two-tier \
  vagrant up acme1 dc1 manage1 stepca1
```

The lab walkthroughs use the raw-vagrant form above (works for `up`,
`ssh`, `halt`, `status`).

## Tool versions on Linux hosts (v2.8.1)

| Tool | Version | Where |
|---|---|---|
| OpenSSL | 3.5 (PQC-enabled) | `scanner1` (`openssl_35` role), `observe1` |
| OpenSSL | 3.0.2 (distro default) | `acme1` (Ubuntu 22.04) — **no `req -not_before/-not_after`** (needs 3.2+); backdate with `faketime` or `openssl ca -startdate/-enddate` |
| step CLI | 0.28.3 | `acme1` (built-in), `scanner1` |
| acme.sh | latest | `acme1` |
| certbot | latest from apt | `acme1` |
| EJBCA | 9.3.7 CE (Docker) | `ejbca1` |
| step-ca | 0.30.2 (Docker) | `stepca1` |
| nmap | apt default | `scanner1` (installed by the `cbom_lens` role) |
| tshark | apt default | `scanner1` (CBOM), most Linux VMs |
| Java | OpenJDK 17 | `tomcat1`, optionally others via apt |

If a version has drifted on your install, the lab's Setup section
re-pins / installs explicitly.

## Tools NOT pre-installed (labs install these inline)

Labs install these in their Setup sections; they are not in
Straylight's default provisioning:

| Tool | Where labs install it | Why not in Straylight |
|---|---|---|
| `testssl.sh` | scanner1 (git clone) | Optional diagnostic, not core PKI infra |
| `nmap` | acme1 (`apt install`); scanner1 already has it via the `cbom_lens` role | Optional outside scanner1 |
| `Certify.exe` (GhostPack) | client1 `C:\Tools\` (manual download) | Offensive security tool; not in default lab provisioning |
| `Rubeus.exe` (GhostPack) | client1 `C:\Tools\` (manual download) | Offensive security tool; not in default lab provisioning |
| `PSPKIAudit` PowerShell module | manage1 / client1 (`Install-Module`) | Optional audit tooling; install on demand |
| `PSCertificateEnrollment` PowerShell module | client1 (`Install-Module`) | Lab-specific module for ESC15 reproduction (parked lab) |
| `mkcert` | acme1 (`apt install` / homebrew) | Dev-only TLS helper; not lab-standard |
| `mitmproxy` | scanner1 (docker run) | Diagnostic / lab-specific |
| `Pebble` (ACME test server) | scanner1 (docker run) | Test scaffolding for the dns-persist-01-pebble lab (parked) |
| HAProxy | scanner1 (`apt install`) | Used only by the webserver-ssl-haproxy lab (parked) |
| Apache (httpd) | scanner1 / fresh VM (`apt install`) | apps1 changed to app-server host in v1.0; Apache no longer there |
| Vault | acme1 / scanner1 (apt repo) | apps1 already has Vault; other hosts install inline |
| Flask (Python) | acme1 / scanner1 (`pip install --user`) | Lab-specific webhook receivers |
| `keytool` (JDK) | tomcat1 has it natively | Java-keystore labs target tomcat1 |
| CAPI2 operational log (Windows) | manage1 / client1 (`wevtutil sl ... /e:true`) | Not enabled by default; the crl-offline labs (parked) enable it in Setup |

On a "command not found" / "not recognized" lab error, check this
table — the tool may need an inline install the lab forgot to
document. Open an issue if so.

### apps1 specifically

Pre-v1.0 labs sometimes assumed `apps1` was a vanilla Apache host.
**In v1.0, apps1 is an applications-platform host** running Keycloak +
Vault + nifi + gitea + minio in Docker. Labs that need Apache (e.g.,
`http-01-apache`, `webserver-ssl-apache`; both parked) install it inline or use a
different host; labs that need Vault can use apps1's existing instance.

## Endpoint defaults

### Step-ca ACME endpoint

```
https://stepca1.yourlab.local:9000/acme/acme/directory
or by IP:
https://192.168.56.51:9000/acme/acme/directory
```

step-ca's root cert lives in the container at
`/home/step/certs/root_ca.crt`. On the host it's at
`/opt/stepca/data/root_ca.pem`. Use `step ca root` to fetch it via
the API.

### AD CS endpoint string

The `-config` flag for `certutil` / `certreq` uses the form
`<hostname>\<CA name>`:

```
issueca\YOURLAB-Issuing-CA            # two-tier (default)
ca1\YOURLAB-Issuing-CA                # one-tier
```

If `LAB_NETBIOS` is overridden, substitute accordingly.

### EJBCA admin endpoint

```
https://ejbca1.yourlab.local:8443/ejbca/adminweb/
```

EJBCA's super-admin credential is generated at provisioning by the
`ejbca_admin_bootstrap` role. The P12 is at
`/opt/ejbca/data/secrets/superadmin.p12` on `ejbca1`, and its
password at `/opt/ejbca/data/secrets/superadmin.pwd`
(`sudo cat` it). The EJBCA CAs are `EJBCA-Root-CA` and
`EJBCA-Issuing-CA`; the admin CA is `EJBCA-Issuing-CA` on the two-tier
EJBCA hierarchy and `EJBCA-Root-CA` on one-tier — there is no separate
"ManagementCA". (`YOURLAB-Issuing-CA` is the AD CS issuing CA, not an
EJBCA CA.)

### CRL / AIA URLs (set by PKI_CONFIG)

```
# Classical hierarchy (rootca / issueca / ca1)
http://pki.yourlab.local/crl
http://pki.yourlab.local/aia

# ML-DSA hierarchy (rootca-pqc / issueca-pqc) — separate namespace
http://pki.yourlab.local/crl/pqc
http://pki.yourlab.local/aia/pqc
```

Hosted on `web1` (192.168.56.30) via IIS; the `pki.yourlab.local`
DNS record points at web1. As of v2.0.0 the classical and ML-DSA
hierarchies use **separate CDP/AIA namespaces** (`/crl` + `/aia` vs
`/crl/pqc` + `/aia/pqc`) — the `publish_ca_artifacts` role writes each
hierarchy into its own subdir, so a revocation or CRL refresh in one
never touches the other. See the
[`labs/adcs-functest-4-revocation-walkthrough.md`](labs/adcs-functest-4-revocation-walkthrough.md)
lab.

## Bringing up the lab for a specific module

The pattern the labs assume:

1. Set up Straylight once per machine via `./scripts/install-wizard.sh`
   from the Straylight repo root.
2. Per lab session, bring up only the needed VMs via
   `LAB_PROFILE=<profile>` or `LAB_COMPONENTS=<csv>` and `bash up.sh`.
3. Run the lab's Setup section in the appropriate VM (usually
   `manage1` or `acme1`).
4. The lab's Cleanup section tears down lab artifacts; VMs stay up
   unless you `vagrant halt` them.

For Tier 5 ADCS-heavy labs (the in-tree `adcs-functest` module;
template-flags, untrustedca, and crl-offline are parked):

```bash
LAB_PROFILE=ad-cs-two-tier bash up.sh
```

For ACME / step-ca / Linux labs (dns-persist-01, mtls, etc.; all
parked):

```bash
LAB_COMPONENTS=acme1,dc1,manage1,stepca1 bash up.sh
```

For PQC labs (`pqc-*` modules; parked):

```bash
LAB_PROFILE=pqc-full bash up.sh   # ~51 GB RAM + Windows
# or Linux-only:
LAB_PROFILE=pqc-linux bash up.sh  # ~19 GB RAM
```

## Where to look in Straylight for ground truth

If a lab seems off, check these Straylight files in order:

1. `ARCHITECTURE.md` — **authoritative VM inventory + role list (69
   roles)**, diagrams, PQC feature matrix, CDP/AIA namespace split.
2. `vagrant/config.rb` — domain, netbios, network, CA names,
   credentials, CDP/AIA URLs (`crl_url`/`aia_url` + `crl_url_pqc`/`aia_url_pqc`).
3. `vagrant/profiles/<name>.yml` — which VMs a profile includes.
4. `vagrant/Vagrantfile` — VM definitions, IP assignments, box
   selection.
5. `vagrant/ansible/roles/<role>/defaults/main.yml` — role-level
   defaults (CA cert validity, KSP choices, etc.).
6. `vagrant/ansible/inventory/group_vars/all.yml` — cross-cutting
   group vars (step-ca CA name, image tags, etc.).
7. `vagrant/docs/lab-topologies.md` — topology + profile catalog.
8. `docs/architecture-evolution.md` — *why* the architecture looks the
   way it does (the 2026-06 remediation: one CBOM envelope,
   validate.sh decomposition, CDP/AIA split, ARCHITECTURE.md as single
   inventory source).
9. `CHANGELOG.md` — what changed in each Straylight release.

**Validate / health-check structure (v2.0.0):** `vagrant/scripts/validate.sh`
is a thin harness (`lib/validate-harness.sh`) plus per-VM checks in
`scripts/checks/<vm>.sh`; shared PQC probes live in
`scripts/lib/pqc-verify/`. To see what's asserted for a VM, read its
`checks/<vm>.sh`.

If a lab's documented value diverges from Straylight, the **Straylight
value is the source of truth** — update the lab to match.
