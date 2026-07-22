# Server Build Workflow

Operator runbook: clean machine to a validated, running topology. All commands
run from `vagrant/`; engine internals and rationale are under [Related](#related).

## 0. Prerequisites

- **Host virtualization must be free for VirtualBox.** Loaded `kvm_amd`/`kvm`
  modules (autoloaded on reboot, or via libvirt/QEMU/emulators) block AMD-V;
  `vagrant up` fails instantly at "Booting VM..." with `VBoxManage: error: Host API has
  not enabled SVME bit in EFER MSR. (VERR_SVM_HOST_SVME_NOT_ENABLED)`. Fix:
  `sudo modprobe -r kvm_amd kvm` in a real terminal (sudo needs a TTY). Intel: `kvm_intel`.
- VirtualBox + Vagrant installed; base boxes present (Windows Server Core /
  Server / Win11 + Ubuntu, per profile). `straylight/*` Windows boxes build from
  one Packer template (`packer/windows/windows-server.pkr.hcl`, `-var win_version=...`
  via `packer/build-images.sh`; [build-process-evolution.md](build-process-evolution.md) §v6);
  they ship **unpatched** — the WSUS golden-master loop (`wsus_server` role +
  `cache-wsus.sh`) patches at runtime.
- Disk headroom: a Windows VM is ~12–43 GB; a 7-VM Windows build wants 150 GB+
  free (`df -h /`, `du -sh ~/"VirtualBox VMs"`); destroy stale generations (§7).
- Optional software cache in `resources/software/` (synced to `C:\Software`);
  needed by offline-sensitive roles, e.g. `KB5087539.msu` for PQC AD CS profiles.

## 1. Pick a profile

`LAB_PROFILE` selects the topology (`vagrant/profiles/<name>.yml`); unset
defaults to `core` (dc1, manage1, web1, ca1). Precedence (low → high): `core` →
`LAB_PROFILE=<name>` → `LAB_COMPONENTS=<csv>` (ad-hoc component list).

```bash
./up.sh --list-profiles          # all profiles + one-line descriptions
./up.sh --show-profile pqc-adcs-two-tier   # components, dotfile dir, VBox prefix
```

Each profile is isolated by dotfile dir (`.vagrant-<profile>`), VBox name prefix
(`straylight-<profile>-<vm>`), and inventory subdir (`ansible/inventory/<profile>/`),
so profiles coexist on one checkout without state or VM-name collisions.

## 2. Build

```bash
LAB_PROFILE=ad-cs-two-tier ./up.sh
```

`up.sh` runs three (optionally four) phases:

1. **Create** all VMs sequentially (`vagrant up --no-provision`) to avoid VirtualBox lock contention.
2. **Provision DC1** (AD DS forest, DNS, OUs); overlapped with Phase 1 by default (`LAB_PHASE2_OVERLAP=true`);
   skipped if `dc1` is absent or already a working DC; failure aborts the build (nothing can domain-join).
3. **Provision the rest** in parallel; roles retry cross-VM dependencies (domain join, Root CA wait, CRL/CDP).

Flags: `--poll SECONDS` (progress cadence, or `VM_POLL` env, default 15s),
`--file FILE` (explicit VM list), `--all` (alias for the `full` profile).

## 3. Monitor

`up.sh` prints colorized per-phase progress; per-VM logs land in
`vagrant/logs/<ts>/` (not the profile dotfile dir):

```
logs/<YYYYMMDD-HHMMSS>/<vm>-create.log     # Phase 1 create
logs/<YYYYMMDD-HHMMSS>/<vm>.log            # Phase 3 provision (Ansible)
```

```bash
tail -f logs/<ts>/issueca.log
VBoxManage list runningvms
```

## 4. Validate

The health check uploads a probe to each running VM over WinRM (Windows) or
SSH (Linux), in parallel, printing PASS/FAIL/SKIP per check; it skips VMs not
in the profile. Run after the build settles and after any Ansible role change.

```bash
bash scripts/validate.sh                 # all running VMs in the active profile
bash scripts/validate.sh dc1 issueca     # only the named VMs
LAB_PROFILE=pqc-adcs-two-tier bash scripts/validate.sh
```

"No running VMs found" means the profile/dotfile doesn't match what's actually up.

## 5. Snapshot (optional)

Snapshot the expensive, deterministic VMs (dc1 forest creation, manage1 RSAT
download); restoring turns an ~8 min DC build into ~20 s.

```bash
LAB_PROFILE=... ./up.sh --save-snap dc1,manage1     # snapshot 'baseline' after build
LAB_PROFILE=... ./up.sh --restore-snap dc1,manage1  # restore instead of build
LAB_PROFILE=... ./up.sh                              # auto-detects 'baseline' snapshots
```

`LAB_AUTO_RESTORE_BASELINE=false` disables auto-restore. `snap.sh` does ad-hoc
save/restore/list/delete (`--name <label>`).

## 6. Iterate on one VM

When one VM fails or one role changes, isolate to that VM; do not nuke and cold-build first.

```bash
./provision.sh issueca           # re-run a VM's playbook (timed, colorized)
LAB_PROFILE=... ./up.sh --rebuild web1,client1   # destroy + recreate + provision (dc1 not allowed)
```

After an interrupted build (Ctrl+C), clear stale locks/processes:

```bash
./clean.sh
```

## 7. Teardown / cleanup

```bash
LAB_PROFILE=... ./nuke.sh        # destroy the active profile's VMs (guarded)
```

Old profile generations each leave a `straylight-<profile>-*` VBox set; destroy
them to reclaim disk. `VBoxManage list runningvms` is authoritative;
`vagrant global-status` caches stale "running" states (refresh with `--prune`).
After direct VBox deletions, check for orphaned `~/VirtualBox VMs/straylight-*` directories.

## Typical full run

```bash
df -h /                                       # confirm headroom
./up.sh --show-profile pqc-adcs-two-tier      # confirm topology
LAB_PROFILE=pqc-adcs-two-tier ./up.sh         # build (watch logs/<ts>/)
LAB_PROFILE=pqc-adcs-two-tier bash scripts/validate.sh   # verify
LAB_PROFILE=pqc-adcs-two-tier ./up.sh --save-snap dc1,manage1   # snapshot for next time
```

## Related

- [build-deployment-pattern.md](build-deployment-pattern.md) — three-phase engine internals
- [build-process-evolution.md](build-process-evolution.md) — build rationale
- [lab-topologies.md](lab-topologies.md) — what each profile contains
- [../../ARCHITECTURE.md](../../ARCHITECTURE.md) — authoritative VM/role inventory (`topology.yml` is the machine-readable source)
- [../../docs/architecture-evolution.md](../../docs/architecture-evolution.md) — the consolidation pass (single sources of truth, validate.sh decomposition, PKI lifecycle)
