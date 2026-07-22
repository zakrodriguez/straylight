# Packer pre-baked images for Straylight

Pre-bake Windows Server boxes with PowerShell 7 + ADCS features + VirtualBox Guest Additions installed. The only cached payload staged at bake time is the PS7 MSI (carried in via a `cd_files` ISO); the rest of the lab software cache is served at runtime by the `C:\Software` synced folder. Cold-builds against a pre-baked box skip the per-VM PS7 MSI install and ADCS feature install — the two flakiest steps in the cold-build path.

## Security: two build modes

The build script is gated on `PACKER_BUILD_FOR_PUBLISH`:

### Default mode (lab daily-driver)

```bash
./build-images.sh 2025
```

Produces a **local-use-only** `.box`: well-known `vagrant:vagrant` credentials, firewall re-enabled on all profiles, autologon credentials (`DefaultPassword`, `AutoAdminLogon`, `DefaultUserName`, `DefaultDomainName`) wiped from the registry, Administrator password left at `vagrant`. **Do NOT push this image to Vagrant Cloud, an internal artifact repo, or any other shared registry.** The script prints a loud banner on every run.

### Publish mode (sysprep-generalized, no known credential)

```bash
PACKER_BUILD_FOR_PUBLISH=1 ./build-images.sh 2025
```

The cleanup phase additionally:

1. Mints a single-use 20-character Administrator password (`[System.Web.Security.Membership]::GeneratePassword(20, 4)`) and prints it to the Packer build log under the banner `ONE-TIME ADMINISTRATOR PASSWORD (single-use, OOBE-only)`. Save it if you need to bridge sysprep to consumer first-boot.
2. Writes `C:\Windows\Panther\publish-unattend.xml` — an unattend that sets the single-use pw in the `oobeSystem` pass (its `specialize` pass sets only `ComputerName`) and **forces the consumer through Windows OOBE setup on first boot**, including the pick-a-new-admin-password prompt.
3. Runs `sysprep /generalize /oobe /shutdown /unattend:C:\Windows\Panther\publish-unattend.xml`.

The post-processor packages a `.box` that embeds `vagrantfile-windows-publish.template`, which has the `winrm.password` line commented out — the consumer must complete OOBE interactively (or supply their own Autounattend) and set the line themselves. Sysprep + generalize adds ~5-10 min to the build.

**Consumer first-boot experience:** `vagrant up` shows the VirtualBox GUI (the publish template sets `vb.gui = true`). The consumer completes OOBE (accept EULA, set a new local Administrator password, sign in), adds `config.winrm.password = "<their new pw>"` to their local Vagrantfile, and re-runs `vagrant up` to continue provisioning.

**Caveats:**

- The single-use pw is visible in the Packer build log. Treat the log as sensitive until the image has been distributed and consumed.
- Sysprep `/generalize` on Server 2025 Core stalls in Packer (see `vagrant/config.rb` — Core variants stay on upstream gusztavvargadr boxes). Publish mode supports **Desktop** SKUs only.
- `vagrantfile-windows-publish.template` is intentionally separate from the default `vagrantfile-windows.template` — the default lab path is untouched.

## Canonical target: Server 2025

The lab's CA VMs (rootca, ca1, issueca) run Server 2025, whose post-domain-join WMI behavior is the source of the `InvalidSelectors` race (19+ rounds of mitigation work). The baked ADCS pre-install does not reach them, though: CA VMs use `BOX_WIN_SERVER_CORE`, which always stays on upstream gusztavvargadr Core boxes (Server 2025 Core sysprep stalls in Packer, and ADCS + sysprep is unsupported per Microsoft), so the race is mitigated at runtime during provisioning. Today the baked ADCS layer benefits no CA VM — it rides in the Desktop-SKU boxes consumed only by the `BOX_WIN_SERVER` VMs (manage1, sqlhost1, tc1), none of which runs a CA.

All four releases build from **one** parameterized template (`windows/windows-server.pkr.hcl`, selected via `-var win_version=<ver>`) sharing a single `windows/answer_files/Autounattend.xml` and the same lab-bake layer. Use the older versions for cross-version testing (e.g., does the lab still work against a Server 2019 CA?) or to compare Server 2025's WMI quirks to older releases.

## Patch baseline: runtime WSUS, not a baked snapshot

These boxes ship **unpatched by design**. `install-updates.ps1` installs the `PSWindowsUpdate` module but does **not** apply updates at bake time — the lab's patch path is the runtime **WSUS golden-master loop** (`wsus_server` Ansible role + `vagrant/scripts/cache-wsus.sh`), which keeps a versioned `WsusContent` + `SUSDB` cache the live VMs pull from. Baking a point-in-time snapshot would (1) duplicate the cache as dead weight inside every box, (2) go stale at the next Patch Tuesday, and (3) re-introduce the reproducibility problem the box-versioning contract removes — two boxes built a month apart would carry silently different update sets. A straylight box is a clean OS + lab-bake layer at a known `box_version`; patch level is owned entirely by WSUS. To experiment with a baked baseline, uncomment the `Get-WindowsUpdate` line in `install-updates.ps1` — but the supported, reproducible path is runtime WSUS.

## Prerequisites

1. **Packer 1.10+** — `apt install packer` or download from <https://developer.hashicorp.com/packer/install>
2. **VirtualBox 7+** with the Extension Pack
3. **Server 2025 Evaluation ISO** from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2025) (~6 GB; eval license is 180 days, renewable via `slmgr /rearm` up to 6 times)
4. **~40 GB free disk** for ISO + working VM + output `.box`
5. **~90 min wall time** for a clean build on a modern host

## Build

### Server 2025 (canonical)

```bash
# 1. Place the ISO
mkdir -p ~/straylight/isos
mv ~/Downloads/SERVER_EVAL_x64FRE_en-us.iso ~/straylight/isos/windows-server-2025.iso

# 2. Compute + pin the checksum (recommended for reproducibility)
export CHECKSUM_2025="sha256:$(sha256sum ~/straylight/isos/windows-server-2025.iso | awk '{print $1}')"

# 3. Build
./build-images.sh 2025

# 4. Verify the box was added
vagrant box list | grep straylight/windows-server-2025
```

### Other versions (2016, 2019, 2022)

Same flow — replace `2025` with the version. Microsoft publishes evaluation ISOs at these direct CDN URLs (no auth gate; eval terms are accepted at first boot, not download):

| Version | fwlink | Image size |
|---|---|---|
| 2016 (Datacenter Desktop) | `https://go.microsoft.com/fwlink/?linkid=2195174` | 6.5 GiB |
| 2019 (Standard Desktop)   | `https://go.microsoft.com/fwlink/?linkid=2195167` | 5.3 GiB |
| 2022 (Standard Desktop)   | `https://go.microsoft.com/fwlink/?linkid=2195280` | 4.7 GiB |
| 2025 (Standard Desktop)   | `https://go.microsoft.com/fwlink/?linkid=2293312` | 5.6 GiB |

Build all four:
```bash
./build-images.sh all
```

Packer phases (see the provisioner blocks in `windows/windows-server.pkr.hcl`):

| Phase | Source | What it does |
|---|---|---|
| 1. Base install | `windows/answer_files/Autounattend.xml` + `scripts/windows/base/setup.ps1` | Unattended Windows install, set Admin pw, enable WinRM listeners + service auth, enable RDP, disable firewall |
| 2. Updates | `scripts/windows/base/install-updates.ps1` | Installs the `PSWindowsUpdate` module only — **updates are NOT applied** (patch baseline is runtime WSUS; see "Patch baseline" above) |
| 3. Guest Additions | `scripts/windows/lab-bake/install-guest-additions.ps1` | Install VirtualBox Guest Additions so the box ships GA-ready, then `windows-restart` |
| 4. **Lab bake** | `scripts/windows/lab-bake/install-pwsh.ps1` + `install-adcs-features.ps1` (see [lab-bake/README.md](scripts/windows/lab-bake/README.md)) | **PS7 MSI + ADCS feature suite**; the PS7 MSI — the sole `cd_files` payload — rides in via the HCL-built `STRAYLIGHT_CACHE` ISO, not a script |
| 5. Cleanup | `scripts/windows/base/cleanup.ps1` | Clear SoftwareDistribution, %TEMP%, event logs, CompactOS, **wipe autologon creds, re-enable firewall**. With `PACKER_BUILD_FOR_PUBLISH=1`, also rotates admin pw + sysprep `/generalize /oobe`. |

> `scripts/windows/base/configure-winrm.ps1` is present but **not wired into any build** — `setup.ps1` already handles the WinRM listener + service-auth config in phase 1. Treat it as unused.

## Using the baked box

After `vagrant box add` succeeds, set `USE_STRAYLIGHT_BOXES=true` (env var or edit in `vagrant/config.rb`) to flip the `BOX_WIN_SERVER` VMs (manage1, sqlhost1, tc1) to the straylight/* boxes; Core-box VMs stay on upstream gusztavvargadr regardless. There is no automatic fallback — box selection is a plain `USE_STRAYLIGHT_BOXES` ternary in `config.rb`, so with the flag set, the straylight box for the selected version must be registered locally or `vagrant up` fails trying to fetch it.

### Pinning a box version (freshness contract)

`build-images.sh` stamps every build with a version (default: UTC datestamp `YYYY.MM.DD`, override with `BOX_VERSION=...`) and registers the box under it, so two rebuilds no longer silently overwrite each other. To guarantee `vagrant up` uses a *specific* bake, pin it:

```bash
export USE_STRAYLIGHT_BOXES=true
export STRAYLIGHT_BOX_VERSION=2026.6.16   # the value build-images.sh printed
```

`config.rb` reads `STRAYLIGHT_BOX_VERSION` and the Vagrantfile threads it into `config.vm.box_version` for straylight/* boxes only (upstream boxes keep their own published versioning). Leave it unset to accept whatever straylight version is registered.

## What the bake saves you

Only the `BOX_WIN_SERVER` VMs — manage1, sqlhost1, tc1 — can consume a straylight box; the CA/dc/web/wsus VMs use `BOX_WIN_SERVER_CORE`, which always stays on upstream gusztavvargadr boxes. On those consumers a pre-baked box short-circuits, per VM at every cold-build:

- `common : Install PowerShell 7 from local cache` (~90s + MSI mutex race)
- Vagrant's Guest Additions install at first `vagrant up`

The ADCS layer the bake also pre-installs (`Pre-install ADCS Cert Authority feature`, `Pre-install additional ADCS features`, the `Restart Winmgmt` WMI-race mitigation) applies only to Ansible tasks that run on CA VMs — which never use baked boxes — so that part of the bake benefits no VM today.

The Ansible roles remain unchanged — their idempotency checks turn into no-ops against a baked box.

## Directory layout

```
packer/
├── README.md                                       # this file
├── build-images.sh                                 # build orchestrator
├── windows/
│   ├── windows-server.pkr.hcl                      # ONE parameterized template (all versions, -var win_version=)
│   ├── answer_files/Autounattend.xml               # ONE shared, version-neutral answer file
│   ├── vagrantfile-windows.template                # output box's embedded Vagrantfile (default mode)
│   └── vagrantfile-windows-publish.template        # ditto, publish mode (placeholder winrm.password)
└── scripts/windows/
    ├── base/                                       # WinRM/firewall/cleanup (used by all builds)
    │   ├── setup.ps1                               # phase 1: WinRM + firewall + RDP
    │   ├── configure-winrm.ps1                     # UNUSED — not wired into any build (setup.ps1 covers WinRM)
    │   ├── install-updates.ps1                     # phase 2: installs PSWindowsUpdate module only (no updates applied — runtime WSUS owns patching)
    │   └── cleanup.ps1                             # phase 5: cleanup / compact / (publish-mode sysprep)
    └── lab-bake/                                   # Straylight-specific pre-install layer
        ├── README.md
        ├── install-guest-additions.ps1            # phase 3: VirtualBox Guest Additions
        ├── install-pwsh.ps1                        # phase 4: PowerShell 7 MSI
        └── install-adcs-features.ps1              # phase 4: ADCS feature suite
```

## Evaluation license notes

Server 2025 evaluation ISOs are valid 180 days, renewable up to 6 times via `slmgr /rearm` (~3 years per ISO). Bake boxes shortly after downloading the ISO so the evaluation clock starts from a known baseline; the bake itself doesn't burn evaluation time, but the *first VM that boots from the box* starts the clock.
