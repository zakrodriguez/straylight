# Lab-bake provisioning layer

These scripts run inside Packer (after WinRM + base config, before
cleanup) to pre-install what the Ansible roles would otherwise install
on every cold-build. Moving the expensive, flaky installs into the bake
step eliminates the runtime WMI/MSI/CertSvc races — there's no
domain-join activity to interfere.

## What gets baked

| Script | What it does | Race it eliminates |
|---|---|---|
| `install-guest-additions.ps1` | Locate the GA ISO attached as a CD-ROM (HCL `guest_additions_mode = "attach"`), pre-trust Oracle's code-signing cert, silent install (`/S`). Followed by a `windows-restart` provisioner to settle the drivers. | Vagrant's `vbguest` plugin re-install at every first `vagrant up` (3-5 min per VM); ensures the `C:\Software` synced folder works from boot zero. CD-attach is ~30-60 s faster than WinRM upload + Mount-DiskImage. |
| `install-pwsh.ps1`   | Install PowerShell 7 from the `STRAYLIGHT_CACHE` CD-ROM Packer builds from `cd_files` (host-cached `vagrant/resources/software/PowerShell-{version}-win-x64.msi`). Native disk-speed read; no WinRM upload. | MSI mutex contention during a cold-build PS7 install, which is hard to mitigate reliably at runtime |
| `install-adcs-features.ps1` | Install ADCS-Cert-Authority + Web-Enrollment + Device-Enrollment + Enroll-Web-Pol + Enroll-Web-Svc, then restart Winmgmt to flush WMI state | Post-feature-install WMI corruption that causes `InvalidSelectors HTTP 500` on the next `microsoft.ad.membership` CIM call — a race that proved hard to eliminate reliably at runtime |

## Cache-first policy

Every Windows install must use a local-cache-first pattern. At runtime,
Vagrant's synced folder (`SOFTWARE_PATH -> C:\Software`) exposes
`vagrant/resources/software/` to guest VMs at `vagrant up` time. The bake
honors the same cache via the HCL's `cd_files` parameter -- Packer builds
a small ISO from the host-cached MSI and attaches it as a CD-ROM (label
`STRAYLIGHT_CACHE`) for a native disk-speed read with no WinRM upload.

No `stage-software.ps1` is needed: pre-fetching Sysinternals, Sysmon,
Beats etc. at bake time was redundant (the synced folder serves them at
runtime once GA is baked) and violated cache-first by hitting
GitHub/elastic.co fresh.

## What stays in Ansible at provision time

- Network / DNS / hostname configuration (per-VM, not bake-able)
- Domain join (per-VM identity, not bake-able)
- ADCS *configuration* (CAType, CAName, CDP, AIA) — per-VM-role
- cert_templates / machine_cert / ca_services (per-role logic)
- All software installs that aren't on the bake's critical-race path
  (Sysinternals/Sysmon/Beats/PSFramework — Ansible reads from
  `C:\Software` synced folder)

The Ansible idempotency contract is unchanged: each role checks current
state first, so re-running against a baked box shortcuts through
"already installed" branches.

## When you change a baked version

If the lab pins a different PS7 version (HCL var `pwsh_version`, default
`7.4.7`), `vagrant/resources/software/PowerShell-{version}-win-x64.msi`
must exist on the host — the MSI is staged through the HCL's `cd_files`,
and a missing file fails the build when Packer assembles the
`STRAYLIGHT_CACHE` CD.
