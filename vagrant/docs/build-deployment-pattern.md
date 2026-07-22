# Build Deployment Pattern

`up.sh` builds the lab in three phases: DC1 must be a functioning domain controller before any other VM can domain-join, so it provisions first; everything else runs in parallel with built-in retry loops.

## Box source (what Phase 1 imports)

Packer builds the Windows base boxes from one parameterized template,
`packer/windows/windows-server.pkr.hcl`, selected with
`-var win_version=<2016|2019|2022|2025>` (see
[build-process-evolution.md](build-process-evolution.md) §v6). `straylight/*`
boxes carry a `box_version` (UTC datestamp by default) that the Vagrantfile pins
via `config.vm.box_version`, so a stale local bake can't silently satisfy
`vagrant up`. Boxes ship unpatched by design — Windows Updates are applied at
provision time through the WSUS golden-master loop (`wsus_server` role +
`cache-wsus.sh`), not baked into the box.

## Phase 1 — Create all VMs sequentially (no provisioning)

`vagrant up <vm> --no-provision` for each VM, one at a time — parallel creates cause VirtualBox "Guest-specific operations" lock errors. Each create takes ~30-60s (box import + VM setup); VMs start booting immediately. With `--restore-snap`, existing snapshots are restored instead.

## Phase 2 — Provision DC1 (overlapped with Phase 1 by default)

`vagrant provision dc1` runs the full DC1 playbook: installs AD-Domain-Services, creates the forest, promotes to DC, configures DNS. By default the provision starts as a background job during Phase 1 — right after dc1's create — so it overlaps the remaining Phase 1 creates; Phase 2 then just waits for that job to finish. Set `LAB_PHASE2_OVERLAP=false` for the sequential, blocking behavior. All other VMs depend on AD DS for domain join, so if DC1 fails, `up.sh` exits. Skipped entirely if DC1 is already a working DC (`nltest /dsgetdc:` passes).

## Phase 3 — Provision everything else in parallel

Remaining VMs provision simultaneously as background jobs (`&`); a live progress monitor polls every 15s and shows colorized status per VM. Each VM's Ansible playbook has built-in retry loops:

- `machine_cert` retries 90x with 20s delay (waits for CA1 to be issuing)
- `domain_join` retries `nltest /dsgetdc:` 45x with 20s delay (waits for DC1's LDAP)

## Default build order (`core` profile)

```
Phase 1: dc1 -> manage1 -> web1 -> ca1  (sequential create)
Phase 2: dc1                            (provision, ~8 min, overlapped with Phase 1 — skipped if dc1 not in profile)
Phase 3: manage1, web1, ca1             (provision in parallel)
```

Phases 1 and 3 iterate `LAB_PROFILE_COMPONENTS_ARR`, so the same
ordering pattern applies to every profile.

## MANAGE1 special case

manage1 runs Server 2025 (Desktop Experience), which ships RSAT on-disk in WinSxS — `Install-WindowsFeature` completes in ~30s with no FoD source needed (`roles/manage/tasks/main.yml`).

> Historical note: before the Server 2025 rebox, manage1 was Windows 11, where RSAT came as Features-on-Demand (~35 min from Windows Update, or ~30s with local FoD cabs) — the reason it pre-launched in Phase 1 to overlap DC1 provisioning. With RSAT on-disk that bottleneck is gone; manage1's cost is now boot + domain join + tooling.

## LAB_PROFILE (14 profiles, see `./up.sh --list-profiles`)

| Profile               | Component count | Use case                                       |
|-----------------------|-----------------|------------------------------------------------|
| `core` (default)      | 4               | DC + CA + IIS + RSAT workstation               |
| `ad-cs-minimal`       | 3               | Smallest viable AD CS demo (~3 GB RAM)         |
| `ad-cs-one-tier`      | 4               | Single Enterprise CA                           |
| `ad-cs-two-tier`      | 5               | Offline root + Enterprise issuing CA           |
| `pqc-linux`           | 6               | PQC migration demo, no Windows / no AD         |
| `pqc-full`            | 13              | PQC migration including Windows AD CS           |
| `pqc-adcs-two-tier`   | 7               | AD CS two-tier + parallel ML-DSA CA hierarchy  |
| `cbom-pipeline`       | 4               | Full CBOM pipeline (3 CAs + scanner)           |
| `observability`       | 2               | OpenSearch + dashboards focus                   |
| `oauth-oidc`          | 3               | Ory Hydra + step-ca TLS backing                |
| `ejbca-only`          | 2               | Pure EJBCA CE play + scanner                    |
| `stepca-only`         | 3               | step-ca + ACME demo                            |
| `sql-cert-labs`       | 6               | Two-tier AD CS + SQL Server 2022 cert binding  |
| `full`                | 18              | Everything                                     |

`--all` is an alias for `LAB_PROFILE=full`.

## Build timing benchmarks (`ad-cs-one-tier` profile)

| Scenario              | DC1   | CA1   | WEB1  | MANAGE1       |
|-----------------------|-------|-------|-------|---------------|
| From scratch          | ~8m   | ~17m  | ~25m  | ~10m          |
| From snapshot         | 21s   | -     | -     | 36s           |

manage1 historical figures: ~46m from scratch on the Win11-era build (RSAT
downloaded from Windows Update), ~10m with local FoD cabs. The Server 2025
rebox installs RSAT from on-disk WinSxS in ~30s, so from-scratch is now ~10m.
