packer {
  required_version = ">= 1.10"
  required_plugins {
    virtualbox = {
      version = ">= 1.0.5"
      source  = "github.com/hashicorp/virtualbox"
    }
    vagrant = {
      version = ">= 1.1.5"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

# Which Windows Server release to build. Selects the VirtualBox guest_os_type
# from the lookup map below; everything else (Autounattend, scripts, lab-bake
# layer) is shared. build-images.sh passes this from its CLI arg.
variable "win_version" {
  type    = string
  default = "2025"

  validation {
    condition     = contains(["2022", "2025"], var.win_version)
    error_message = "Variable win_version must be one of: 2022, 2025."
  }
}

# Box freshness contract. Threaded into the vagrant post-processor's
# output name and into the box metadata so `config.vm.box_version` can pin a
# specific bake. build-images.sh defaults this to a UTC datestamp (YYYY.MM.DD)
# so two rebuilds of the same OS no longer silently overwrite each other under
# an identical name+version. Override with -var box_version=... for a manual pin.
variable "box_version" {
  type    = string
  default = "0.0.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.box_version))
    error_message = "Variable box_version must be a 3-part numeric version such as 2026.6.16 for Vagrant box_version compatibility."
  }
}

variable "iso_url" {
  type    = string
  default = ""
}

variable "iso_checksum" {
  type    = string
  default = ""
}

variable "vm_name" {
  type    = string
  default = ""
}

variable "output_directory" {
  type    = string
  default = ""
}

variable "disk_size_mb" {
  type    = number
  default = 81920
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "cpus" {
  type    = number
  default = 4
}

variable "headless" {
  type    = bool
  default = true
}

variable "pwsh_version" {
  type    = string
  default = "7.4.7"
}

# When true, the cleanup provisioner runs sysprep /generalize /oobe /shutdown
# (rotating the Administrator pw to a one-time random value baked into a
# generated publish-unattend.xml) and the vagrant post-processor uses the
# publish-mode Vagrantfile template that ships with a placeholder pw line.
# build-images.sh wires this from PACKER_BUILD_FOR_PUBLISH=1.
variable "publish_mode" {
  type    = bool
  default = false
}

locals {
  # The only per-release difference between the old per-version templates.
  # 2022 and 2025 both use the Windows2022_64 guest type (VirtualBox has no
  # dedicated 2025 profile yet).
  guest_os_types = {
    "2022" = "Windows2022_64"
    "2025" = "Windows2022_64"
  }
  guest_os_type = local.guest_os_types[var.win_version]

  # Derive the conventional names when the caller doesn't override them, so a
  # bare `packer build -var win_version=2019` still produces the expected
  # straylight-windows-server-2019 artifact + ./output-2019 working dir.
  vm_name          = var.vm_name != "" ? var.vm_name : "straylight-windows-server-${var.win_version}"
  output_directory = var.output_directory != "" ? var.output_directory : "./output-${var.win_version}"
}

source "virtualbox-iso" "windows-server" {
  guest_os_type = local.guest_os_type

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  vm_name          = local.vm_name
  output_directory = local.output_directory

  disk_size = var.disk_size_mb
  memory    = var.memory_mb
  cpus      = var.cpus
  headless  = var.headless

  communicator   = "winrm"
  winrm_username = "vagrant"
  winrm_password = "vagrant"
  winrm_timeout  = "12h"
  winrm_use_ssl  = false
  winrm_insecure = true

  boot_wait = "5s"
  # In publish mode, cleanup.ps1 invokes sysprep /shutdown directly, so we
  # leave shutdown_command empty and let Packer wait for the VM to power
  # itself off. Sysprep + generalize can take several extra minutes.
  shutdown_command = var.publish_mode ? "" : "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = var.publish_mode ? "60m" : "30m"

  # Attach the GA ISO as a secondary CD-ROM (faster than WinRM upload).
  # The install-guest-additions.ps1 script locates it by scanning CD volumes
  # for VBoxWindowsAdditions.exe.
  guest_additions_mode = "attach"

  # Stage host-cached software as a Packer-built ISO mounted as a CD-ROM
  # with label STRAYLIGHT_CACHE. Scripts read directly off the CD.
  cd_label = "STRAYLIGHT_CACHE"
  cd_files = [
    "../../vagrant/resources/software/PowerShell-${var.pwsh_version}-win-x64.msi",
  ]

  floppy_files = [
    "./answer_files/Autounattend.xml",
    "../scripts/windows/base/setup.ps1",
  ]

  vboxmanage = [
    ["modifyvm", "{{ .Name }}", "--clipboard-mode", "bidirectional"],
    ["modifyvm", "{{ .Name }}", "--draganddrop", "bidirectional"],
    ["modifyvm", "{{ .Name }}", "--vrde", "off"],
    ["modifyvm", "{{ .Name }}", "--audio-driver", "none"],
  ]
}

build {
  name = "windows-server"

  sources = ["source.virtualbox-iso.windows-server"]

  # ---------------------------------------------------------------------------
  # Phase 1: base WinRM + firewall + RDP (matches existing 2016/2019/2022 base)
  # ---------------------------------------------------------------------------
  # NOTE: this image ships UNPATCHED by design. Windows Updates are applied at
  # runtime via the lab's WSUS server (the `wsus_server` Ansible role +
  # cache-wsus.sh golden-master loop), NOT baked. See packer/README.md
  # ("Patch baseline") for the rationale.
  provisioner "powershell" {
    scripts = [
      "../scripts/windows/base/install-updates.ps1",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 1.5: Install VirtualBox Guest Additions so the box ships ready for
  # the lab synced-folder pattern (C:\Software). Without GA, Vagrant's vbguest
  # plugin would re-install at first vagrant up -- 3-5 min per VM. Bake it once.
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    scripts = [
      "../scripts/windows/lab-bake/install-guest-additions.ps1",
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  # ---------------------------------------------------------------------------
  # Phase 2: lab-bake layer -- pre-install everything the Ansible roles install
  # at provision time on every cold-build. This is the time-saver layer:
  # PS7 MSI + ADCS features happen ONCE here, not per-VM per-build.
  # See packer/scripts/windows/lab-bake/README for the full bake contract.
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = [
      "PWSH_VERSION=${var.pwsh_version}",
    ]
    scripts = [
      "../scripts/windows/lab-bake/install-pwsh.ps1",
      "../scripts/windows/lab-bake/install-adcs-features.ps1",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 3: cleanup + compact. In publish mode the env var triggers the
  # opt-in branch at the END of cleanup.ps1 that rotates the admin pw to a
  # one-time value, writes publish-unattend.xml, and sysprep-generalizes.
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = [
      "PACKER_BUILD_FOR_PUBLISH=${var.publish_mode ? "1" : "0"}",
    ]
    scripts = [
      "../scripts/windows/base/cleanup.ps1",
    ]
  }

  post-processor "vagrant" {
    output               = "./box/${local.vm_name}-${var.box_version}.box"
    vagrantfile_template = var.publish_mode ? "./vagrantfile-windows-publish.template" : "./vagrantfile-windows.template"
    keep_input_artifact  = false
  }
}
