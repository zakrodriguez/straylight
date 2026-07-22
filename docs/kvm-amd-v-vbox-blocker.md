# KVM holds AMD-V → VirtualBox blocker

With the Linux KVM modules (`kvm_amd` + `kvm`) loaded, VirtualBox dies at the **first VM** (dc1):

```
VBoxManage: error: Host API has not enabled SVME bit in EFER MSR. (VERR_SVM_HOST_SVME_NOT_ENABLED)
VBoxManage: error: Details: code NS_ERROR_FAILURE (0x80004005), component ConsoleWrap, interface IConsole
```

On an AMD host (e.g. Ryzen 9 3950X), KVM claims AMD-V/SVM exclusively, so `vboxdrv` can't enable the SVME bit. Host-environment issue — not lab code or BIOS.

## Diagnosis (confirms it's this, not BIOS)

```bash
grep -c svm /proc/cpuinfo      # → 32  ⇒ AMD-V IS enabled in BIOS (silicon, unaffected by the module)
lsmod | grep -i kvm            # → kvm_amd / kvm present ⇒ smoking gun
```

- `svm` present in `/proc/cpuinfo` ⇒ CPU/BIOS is never the culprit.
- `lsmod` 3rd column = refcount + users:

  ```
  kvm_amd   241664   0          # 0 = nothing actively using it ⇒ safe to unload
  kvm       1445888  1 kvm_amd  # held by kvm_amd ⇒ remove kvm_amd first
  ```

- The condition is host-global: profiles containing dc1 fail there because it's the first VM started; profiles without dc1 (the Linux-only ones) fail at their own first VM. Unrelated to the multi-profile IP-collision issue.

## How it gets loaded

Usually not at boot and not in any modprobe config: the kernel/udev autoloads `kvm_amd` via MODALIAS the moment a program touches `/dev/kvm` (GNOME Boxes, an Android emulator, qemu, `kvm-ok`, `virt-host-validate`). Confirm it loaded after boot:

```bash
stat -c '%y' /sys/module/kvm_amd   # vs:
uptime -s                          # appeared minutes after boot ⇒ on-demand autoload
journalctl -k | grep -i kvm        # kernel log line for the load
```

## Quick fix (runtime, reversible)

```bash
sudo modprobe -r kvm_amd kvm       # frees AMD-V for VBox
# reload anytime with:  sudo modprobe kvm_amd
```

Unloading is safe when the refcount is `0` (no KVM VM running).

## Durable fix (block the autoload)

```bash
printf 'blacklist kvm_amd\nblacklist kvm\n' | sudo tee /etc/modprobe.d/blacklist-kvm-for-vbox.conf
```

`blacklist` stops only the autoload/modalias path — the trigger here, so it's sufficient. If anything explicitly runs `modprobe kvm_amd`, block every load path instead:

```bash
printf 'install kvm_amd /bin/false\ninstall kvm /bin/false\n' | sudo tee /etc/modprobe.d/blacklist-kvm-for-vbox.conf
```

Reverse with:

```bash
sudo rm /etc/modprobe.d/blacklist-kvm-for-vbox.conf && sudo modprobe kvm_amd
```

Only one driver can own AMD-V at a time; blacklisting KVM leaves it to `vboxdrv`. The `svm` flag stays in `/proc/cpuinfo` because that's the silicon advertising the feature, not the driver claiming it. **Trade-off:** while KVM is blocked you can't run qemu/libvirt/GNOME Boxes VMs. If you bounce between both, skip the config file and `modprobe -r` / `modprobe` around VirtualBox sessions.

## TL;DR

If a cold build fast-fails at dc1 with `VERR_SVM_HOST_SVME_NOT_ENABLED`:

```bash
lsmod | grep -i kvm && sudo modprobe -r kvm_amd kvm   # then re-run the build
```
