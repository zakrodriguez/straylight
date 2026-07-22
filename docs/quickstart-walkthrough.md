# Quickstart Walkthrough

A guided first run through Straylight. Time-budget: ~30 minutes for `core` profile (4 VMs), ~95–110 minutes for `pqc-full` (13 VMs). Text-only: every expected outcome is a command transcript, log excerpt, or named artifact you can `grep` or open.

## 1. Prerequisites

```bash
git clone https://github.com/zakrodriguez/straylight
cd straylight

# Confirm host OS support
./scripts/install-wizard.sh --list-supported-hosts
```

Expected output ends with `Detected on this host: linux (ubuntu)`. Anything else → see [README.md — Requirements](../README.md#requirements).

## 2. Install prerequisites

```bash
./scripts/install-wizard.sh --prereqs-only
```

The wizard checks for and installs (with sudo prompts):

- Python 3.10+ + pipx
- git, sshpass
- VirtualBox 7.x + Extension Pack
- Vagrant + the `vagrant-vbguest` plugin
- Ansible + collections from `vagrant/ansible/requirements.yml`

Expect `[wizard]` log lines and `✓ component name (version)` ticks; ~5-10 minutes the first time (VirtualBox download is the slowest piece).

**After install completes, log out and back in** for `vboxusers` group membership to take effect.

## 3. Choose a profile + bring up the lab

```bash
cd vagrant
./up.sh --list-profiles
```

This lists 14 profiles with one-line descriptions. Three starting points:

| Profile | VMs | Use case | Build time |
|---|---|---|---|
| `core` | 4 | Default Microsoft PKI lab | ~30 min |
| `ad-cs-two-tier` | 5 | Two-tier AD CS (offline root) | ~45–50 min |
| `pqc-full` | 13 | Full PQC migration demo | ~95–110 min |

Start the build:

```bash
LAB_PROFILE=ad-cs-two-tier ./up.sh
```

What you'll see:

```
═══ Creating 5 VMs (sequential, no-provision) ═══

  OK    dc1          (3m10s)  [3m10s]
  10:04:12 [3m10s]  dc1 provision started in background (PID 51234, log: logs/<run-id>/dc1.log)
  OK    rootca       (2m45s)  [5m55s]
  ...

═══ Waiting for DC1 provision (overlap with Phase 1) ═══

  10:15:40 [14m38s]  dc1 waiting on background PID 51234...
  10:24:02 [23m00s]  dc1 ✓ background provision finished
  10:24:02 [23m00s]  dc1 ✓ done (19m 50s)

═══ Provisioning 4 VMs in parallel ═══

  10:24:03 [23m01s]  staggering 60s before launching next CA VM (avoids domain_join WMI race)
  ...
  10:45:20 [44m18s]  issueca    ✓ done (21m 17s)
```

VM creation runs sequentially (avoids Vagrant lock contention). dc1's provision — the AD forest build — starts in the background as soon as dc1's VM exists (Phase 2 overlap, on by default), and `up.sh` waits for it before the parallel phase. Everything else then provisions in parallel, with a 60s stagger between consecutive CA VMs (rootca, issueca) to avoid a domain-join WMI race on dc1.

**If a VM line ends `FAIL` (create) or `✗ FAILED` (provision)** — the per-VM log is in `vagrant/logs/<run-id>/<vm>.log`. Common first-time failures:

- **Domain join timeout** on `manage1` — DC1 promotion is usually still finishing; retry with `vagrant provision manage1`.
- **VirtualBox lock contention** — `up.sh` retries automatically. Note `nuke.sh` only sees the active profile's VMs (its `vagrant status` is scoped to the per-profile dotfile); orphaned `straylight-*` VMs from interrupted runs need manual cleanup: find them with `vboxmanage list vms`, then `VBoxManage unregistervm <name> --delete`.

## 4. Validate

```bash
LAB_PROFILE=ad-cs-two-tier bash scripts/validate.sh
```

Runs ~95 checks for `ad-cs-two-tier`, color-coded: green `PASS` (most), yellow `SKIP` (checks gated to VMs absent from the active profile), red `FAIL` (real problems). Summary at the end:
```
=== Summary (312s) ===
  PASS: 93    FAIL: 0    SKIP: 2
  log: ...
```

For a healthy `ad-cs-two-tier` lab, target is **0 FAIL** — recorded healthy runs land around 93 PASS / 0 FAIL / 2-4 SKIP. Check and SKIP counts vary by profile.

## 5. Explore the lab

### RDP into the admin workstation

```bash
vagrant rdp manage1
```

Login: `vagrant` / `vagrant` (or `Administrator` / `TenTowns00!`).

Open `certlm.msc`. Expect:

- **Trusted Root CAs**: `YOURLAB-Root-CA` published by AD GPO.
- **Personal**: machine cert auto-enrolled (issued by the Issuing CA).

### OpenSearch Dashboards

For profiles with `observe1` (`pqc-full`, `pqc-linux`, `observability`, `cbom-pipeline`, `full`, `oauth-oidc`, `stepca-only`):

```
https://192.168.56.53/
```

nginx (the `observe_tls` role) terminates TLS on :443 and proxies to OSD; OSD's own :5601 listens on loopback only.

- 7 dashboards under the `CBOM:` prefix
- **CBOM: Cross-Protocol PQC Posture** — three count-metric panels (TLS PQC Endpoints, SSH PQC KEX, OpenPGP PQC Subkeys) with per-scanner and per-VM drilldowns below.
- **CBOM: Drift Detection** — updates when the CBOM pipeline re-scans and the crypto inventory changes between runs.

### EJBCA admin UI

For profiles with `ejbca1` (`pqc-full`, `pqc-linux`, `full`, `cbom-pipeline`, `ejbca-only` — note `pqc-adcs-two-tier` has no ejbca1):

```
https://192.168.56.50:8443/ejbca/adminweb/
```

EJBCA requires client cert auth via browser P12 import. ejbca1 has no `/vagrant` synced folder, so pull the P12 over SSH (run on the host):

```bash
vagrant ssh ejbca1 -c "sudo base64 /opt/ejbca/data/secrets/superadmin.p12" | tr -d '\r' | base64 -d > superadmin.p12
vagrant ssh ejbca1 -c "sudo cat /opt/ejbca/data/secrets/superadmin.pwd"
# Import superadmin.p12 (password from the second command) into Firefox/Chrome
```

The admin UI lists `EJBCA-PQC-Root-CA` and `EJBCA-PQC-Issuing-CA` (pure ML-DSA-65 signing) plus `EJBCA-Chimera-Root-CA` (RSA-4096 primary signing key with an ML-DSA-65 alternative signing key).

### Pure-PQC TLS handshake proof

The pure-PQC endpoints are not part of the base `pqc-full` provision — stand them up first (from `vagrant/`):

```bash
ansible-playbook -i ansible/inventory/$LAB_PROFILE/pqc.ini ansible/playbooks/pqc-pure-leaf.yml \
  -e "ejbca_token_password=foo123 lab_domain=yourlab.local"
LAB_PROFILE=pqc-full ansible-playbook -i ansible/inventory/$LAB_PROFILE/pqc.ini \
  ansible/playbooks/pqc-mtls.yml -e ejbca_token_password=foo123
```

`pqc-pure-leaf.yml` enrolls the ML-DSA-65 leaf and starts the :8444 listener on observe1; `pqc-mtls.yml` puts OpenSSL 3.5 and the PQC CA chain on scanner1. Then see ML-DSA-65 in an actual TLS handshake:

```bash
vagrant ssh scanner1
echo | /opt/openssl-3.5/bin/openssl s_client -connect 192.168.56.53:8444 \
  -CAfile /opt/pqc-certs/ejbca-pqc-chain.pem -groups X25519MLKEM768 2>/dev/null \
  | /opt/openssl-3.5/bin/openssl x509 -noout -text \
  | grep "Public Key Algorithm"
```

Expected line:

```
Public Key Algorithm: ML-DSA-65
```

System OpenSSL 3.0 will fail the same connection: pure-PQC endpoints cannot be reached by classical clients.

## 6. Snapshot before experimenting

```bash
./snap.sh save dc1 rootca issueca web1 manage1 --name healthy-baseline
```

Stores a VirtualBox snapshot of every VM in the active profile — useful before debugging a role change or testing the PQC remediation orchestrator. Restore later:

```bash
./snap.sh restore dc1 rootca issueca web1 manage1 --name healthy-baseline
```

## 7. Clean up

```bash
./nuke.sh --yes-delete-without-prompt
```

Destroys every VM in the active profile — scoped via the per-profile Vagrant dotfile, so other profiles' VMs are untouched. The `straylight-<profile>-*` VBox names are used only to hard-poweroff running VMs faster before destroy. Complete reset:

```bash
rm -rf .vagrant-*/
```

## Next steps

- **PQC demo flow**: [vagrant/docs/pqc-demo-runbook.md](../vagrant/docs/pqc-demo-runbook.md) — narrative for a PKI-literate audience.
- **Architecture**: [ARCHITECTURE.md](../ARCHITECTURE.md) — composition-model diagrams + PQC feature matrix.
- **Contributing**: [CONTRIBUTING.md](../CONTRIBUTING.md) — no pull requests, and Issues are disabled; security reports go through [SECURITY.md](../SECURITY.md). Fork freely.
