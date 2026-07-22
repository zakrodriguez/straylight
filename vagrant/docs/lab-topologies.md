# Lab Topologies

The lab supports two AD CS topologies plus a PQC variant, selected via `LAB_PROFILE`:

| Profile | Topology | CA Layout |
|---|---|---|
| `ad-cs-one-tier` | One-tier | Single Enterprise Root CA (`ca1`) acts as both root and issuer |
| `ad-cs-two-tier` | Two-tier | Offline Standalone Root (`rootca`) signs an Enterprise Issuing CA (`issueca`) |
| `pqc-adcs-two-tier` | Two-tier + PQC | Classical two-tier hierarchy alongside a parallel ML-DSA hierarchy: `rootca-pqc` (ML-DSA-87 standalone root) signs `issueca-pqc` (ML-DSA-65 sub-CA) |

Topology is driven by the profile's component list in `profiles/<name>.yml` — there are no per-topology directories.

## VM inventory — single source of truth

The authoritative VM list (every host, IP, role, memory, autostart flag) is
`vagrant/topology.yml`, the machine-readable source the Vagrantfile reads. The
human-readable inventory — VMs plus the **69 Ansible roles** — is in
[../../ARCHITECTURE.md](../../ARCHITECTURE.md). This doc covers only what
differs by topology and how the profiles deploy; see
[../../docs/architecture-evolution.md](../../docs/architecture-evolution.md)
for why `topology.yml` became the single source.

## Quick start

```bash
# Two-tier (recommended default)
LAB_PROFILE=ad-cs-two-tier ./up.sh

# One-tier
LAB_PROFILE=ad-cs-one-tier ./up.sh

# Status / RDP / re-provision
vagrant status
vagrant rdp manage1
vagrant provision issueca
```

`up.sh` runs the parallel build with the staggered launch order for the selected profile.

## Deployment order

**One-tier** (`ad-cs-one-tier`): `dc1`, `ca1`, `web1`, `manage1`
1. `dc1` (creates AD forest)
2. `ca1` (joins domain, installs Enterprise CA)
3. `web1` (joins domain, sets up IIS)
4. `manage1` (joins domain, RSAT management workstation, receives autoenrolled machine cert)

**Two-tier** (`ad-cs-two-tier`): `dc1`, `rootca`, `issueca`, `web1`, `manage1`
1. `dc1` (creates AD forest)
2. `web1` (joins domain, sets up IIS for CRL/AIA)
3. `rootca` (standalone CA, publishes cert/CRL to web1)
4. `issueca` (joins domain, subordinate CA signed by rootca)
5. `manage1` (joins domain, RSAT management workstation, receives autoenrolled machine cert)

Neither AD CS profile includes `client1`; the Win 11 client perspective ships only in the `full` profile.

**PQC two-tier** (`pqc-adcs-two-tier`): the two-tier build plus a parallel
ML-DSA hierarchy — 7 VMs: `dc1`, `rootca`, `issueca`, `rootca-pqc`,
`issueca-pqc`, `web1`, `manage1`. `rootca-pqc` (ML-DSA-87 standalone root)
signs `issueca-pqc` (ML-DSA-65 sub-CA); both share `web1` for CRL/AIA, and
`manage1` trusts both root CAs forest-wide. PQC CAs require KB5087539
(Server 2025 May 2026 cumulative).

The PQC hierarchy publishes CDP/AIA into a separate `/crl/pqc` + `/aia/pqc`
namespace on `web1`, so classical and PQC artifacts never collide. The
`ca_crl_republish` role keeps each online issuing CA's CRL fresh via a daily
SYSTEM scheduled task that republishes to web1 independent of the 26-week CRL
base period; the PQC issuing CA sets `publish_subdir: pqc` to republish into
`\crl\pqc`. Offline standalone roots are excluded — their CRL is long-lived
by design and they sit powered off.

## Optional VMs

Optional VMs have `autostart: false`. Bring them up explicitly after the core lab is healthy:

```bash
vagrant up wsus1 dc2                  # Windows extras
vagrant up ejbca1 stepca1             # alternative CAs (EJBCA CE, step-ca)
vagrant up tomcat1                    # Windows Tomcat application host (PQC keystore target, not a CA)
vagrant up hydra1 observe1            # OAuth + observability
```

`manage1` is in the core profiles but also has `autostart: false` — `up.sh`
builds it as part of the profile, but a bare `vagrant up` skips it; start it
explicitly with `vagrant up manage1` if needed.

After provisioning ejbca1 or stepca1, publish their root certs into AD:

```bash
vagrant provision dc1 --provision-with ejbca-trust
vagrant provision dc1 --provision-with stepca-trust
```

## Validation

```bash
LAB_PROFILE=<profile> bash scripts/validate.sh
```

## Two-tier considerations

**Why two-tier?**
- Root CA private key is protected (offline after signing the subordinate)
- Issuing CA can be rebuilt without replacing the root trust
- Matches enterprise best practices

**Taking the root CA offline.** After initial provision + subordinate signing:

```bash
vagrant halt rootca
```

Only bring `rootca` online to sign a new subordinate, renew the issuing CA cert, or publish an updated CRL (every 6 months by default).

**Root CRL publication** — manual, from `rootca` when online (online issuing
CAs are refreshed automatically by the `ca_crl_republish` daily task):

```powershell
certutil -crl
Copy-Item C:\Windows\System32\CertSrv\CertEnroll\*.crl \\192.168.56.30\PKI$\crl\
```

After a long offline period, see [pqc-demo-runbook.md](./pqc-demo-runbook.md) cold-start CRL refresh section.

## Features enabled (both topologies)

- Web Enrollment, NDES, CEP/CES
- Autoenrollment GPO
- Custom certificate templates

Key Archival is deliberately **not** enabled: the `ca_services` role leaves
`KRAF_ENABLEARCHIVEALL` off until KRA certificate enrollment and registration
are automated (see the "Enable Key Archival" task comment in
`ansible/roles/ca_services/tasks/main.yml`).

## URLs

| Service | URL |
|---|---|
| Web Enrollment | `http://ca1.yourlab.local/certsrv` (one-tier) / `http://issueca.yourlab.local/certsrv` (two-tier) |
| NDES | `…/certsrv/mscep/mscep.dll` on the same host |
| CRL (classical) | `http://pki.yourlab.local/crl/` |
| AIA (classical) | `http://pki.yourlab.local/aia/` |
| CRL (PQC hierarchy) | `http://pki.yourlab.local/crl/pqc/` |
| AIA (PQC hierarchy) | `http://pki.yourlab.local/aia/pqc/` |
| EJBCA Admin | `https://192.168.56.50:8443/ejbca/adminweb/` |
| step-ca ACME | `https://192.168.56.51:9000/acme/acme/directory` |

## Credentials

| Account | Password |
|---|---|
| Administrator | `TenTowns00!` |
| vagrant | `vagrant` |
| svc-ndes | `SvcPKI00!` |
| svc-cep | `SvcPKI00!` |
| svc-ces | `SvcPKI00!` |

## Certificate chain (two-tier)

```
[Root CA] — YOURLAB-Root-CA (Standalone, Offline)
   └── [Issuing CA] — YOURLAB-Issuing-CA (Enterprise, Online)
           └── [End-entity certificates]
```

## Snapshots

Snapshot management is profile-aware via `snap.sh` at the lab root — it reads `LAB_PROFILE` and operates on the matching `VAGRANT_DOTFILE_PATH`, so multiple profiles can hold independent snapshot trees:

```bash
./snap.sh save dc1 rootca issueca web1 manage1 --name healthy-baseline
./snap.sh restore dc1 rootca issueca web1 manage1 --name healthy-baseline
./snap.sh list
```

`snap.sh <save|restore>` takes an explicit VM list; `--name NAME` selects the
snapshot name (default `baseline`).
