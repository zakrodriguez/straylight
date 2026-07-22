# Build Process Evolution

## v1: Sequential Everything
`vagrant up` per VM, one at a time: DC1, then CA1, WEB1, CLIENT1. Total build time: 60+ minutes for the core four.

## v2: Staggered Parallel (`up.sh`)
DC1 builds sequentially (AD DS required first); remaining VMs launch in background with a stagger delay (default 6 minutes).

**Problem:** every `vagrant up` grabs a global machine index lock, so 4+ VMs launching in overlapping windows fight over it. Retries (3x with 30s delay) helped but didn't eliminate the issue.

## v3: Manage1 Pre-Launch
manage1 launches before DC1, boots (~160s for Win11), and starts its ~35 min RSAT download while DC1 builds — RSAT overlaps DC1 forest creation instead of running after it.

> Historical note: this v3 stage predates the manage1 rebox — manage1 was Windows 11 then. manage1 was later moved to Windows Server 2025 (Desktop Experience), which ships RSAT on-disk (~30s install), so this RSAT-download overlap no longer applies.

## v4: Snapshot Support (`--save-snap` / `--restore-snap`)
VirtualBox snapshot save/restore. First build: `--save-snap dc1,manage1`. Subsequent builds: `--restore-snap dc1,manage1` skips forest creation (~8 min) and RSAT download (~35 min).

**Results:**
- DC1: 8 min build → 21 sec restore
- manage1: 46 min build → 36 sec restore
- Full core four rebuild: 27 min 27 sec (with dc1+manage1 from snapshot)

**Companion scripts:**
- `snap.sh` — ad-hoc snapshot management (save/restore/list/delete with --name)
- `clean.sh` — cleanup after Ctrl+C (kill stale processes, clear lock files)
- `nuke.sh` — destroy VMs safely (dry-run default, --keep/--only filters)

## v5: Three-Phase Build (Current)
Separates VM creation from provisioning, eliminating lock contention.

**Phase 1: Create** — all VMs created sequentially with `vagrant up --no-provision`, 30-60s each (Server Core) or ~160s (Win11). VMs boot immediately after creation.

**Phase 2: Provision DC1** — AD DS forest creation, DNS, OUs, service accounts. Everything else depends on this.

**Phase 3: Provision in parallel** — all remaining VMs provision simultaneously over WinRM inside already-booted VMs; no locks needed. Retry loops handle dependency ordering:
- `domain_join`: retries `nltest /dsgetdc:` until DC1 is ready (45 retries x 20s)
- `machine_cert`: retries cert request until CA1 issues it (90 retries x 20s)
- `subordinate_ca`: retries `certutil -ping` until ROOTCA responds (75 retries x 20s, ~25 min)

**Why it works:** the global lock is only needed during `vagrant up` (box import, VM config, network setup); `vagrant provision` just opens a WinRM session to a running VM. Front-loading all creates sequentially removes contention, then all slow provisioning runs in parallel.

## Stagger → No Stagger

| Version | Approach | Lock Contention | Parallelism |
|---------|----------|-----------------|-------------|
| v1 | Sequential | None (one at a time) | None |
| v2 | Staggered parallel | Frequent (overlapping `vagrant up`) | Partial (stagger gaps) |
| v3 | Pre-launch manage1 | Same as v2 | Better (manage1 overlaps DC1) |
| v4 | + Snapshots | Same as v2 (for non-snapshot VMs) | Much better (skip slow VMs) |
| v5 | Three-phase | None (sequential create) | Full (all provision in parallel) |

## v6: One Parameterized Packer Template (box build)

A parallel evolution on the *box* side (not the `up.sh` runtime). The base Windows boxes were originally built from four near-identical per-version Packer templates under `packer/windows/{2016,2019,2022,2025}/`, which drifted: a fix to the 2022 Autounattend or bake layer had to be hand-copied into three siblings. They are replaced by **one** parameterized template, `packer/windows/windows-server.pkr.hcl`, selected with `-var win_version=<2022|2025>` (the 2016/2019 lanes were dropped in the curation pass — never live-tested). A `locals` lookup map holds the only real per-release difference — the VirtualBox `guest_os_type` (2022 and 2025 both map to `Windows2022_64`; VBox has no dedicated 2025 profile yet). One shared `packer/windows/answer_files/Autounattend.xml` and one shared bake-layer script set serve all releases; `build-images.sh` passes `win_version` from its CLI arg.

**Box freshness contract (`box_version`).** Two rebuilds of the same OS used to silently overwrite each other under an identical box name. `build-images.sh` now defaults `box_version` to a UTC datestamp (`YYYY.MM.DD`), threaded through the vagrant post-processor's output name and into the box metadata. The Vagrantfile pins `config.vm.box_version` for `straylight/*` boxes (when `STRAYLIGHT_BOX_VERSION` is set in `config.rb`) so a stale local bake can't silently satisfy `vagrant up`. Upstream `gusztavvargadr` boxes keep Vagrant's default version resolution.

**Patch baseline — boxes ship unpatched by design.** The bake layer installs PowerShell 7, AD CS features, and Guest Additions once, but no Windows Update baseline. Patching is a runtime concern: the lab's WSUS golden-master loop (`wsus_server` Ansible role + `cache-wsus.sh`) applies updates to the running VMs. Baking patches would stale-date and bloat the box; the WSUS path keeps a single, observable patch source of truth. See `packer/README.md` ("Patch baseline").

See [docs/architecture-evolution.md](../../docs/architecture-evolution.md) for the wider consolidation this collapse was part of.

## Key Lessons

1. **Vagrant's global lock is the core constraint.** Any `vagrant up/halt/destroy/snapshot` command grabs it; the only safe parallel operation is `vagrant provision`.

2. **Separate create from provision.** Creation is fast but needs the lock; provisioning is slow but doesn't. Do them in different phases.

3. **Retry loops are the coordination mechanism.** Each VM retries its dependencies instead of relying on explicit ordering (CA1 before WEB1), allowing full parallel provisioning without orchestration complexity.

4. **Snapshot the expensive VMs.** DC1 (forest creation) and manage1 (RSAT download) are the two bottlenecks; snapshotting them turns a 45-minute build into a 1-minute restore.

5. **Win11 VMs boot slowly.** Server Core: ~60-80s. Win11: ~160s. The create phase is dominated by Win11 boot time, not box import.

6. **One template instead of four.** Per-version Packer templates drift. Parameterize the single difference (`guest_os_type`) and share everything else. Patch at runtime via WSUS, not in the baked baseline, so the artifact doesn't stale-date.
