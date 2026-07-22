# Straylight PKI Lab - Shared Configuration
# This file is loaded by all topology Vagrantfiles

#===============================================================================
# Lab Settings
#===============================================================================
# Override via environment variables to run multiple profiles simultaneously:
#   LAB_DOMAIN=testlab.local LAB_NETBIOS=TESTLAB LAB_NETWORK=192.168.57 \
#     LAB_PROFILE=ad-cs-one-tier bash up.sh
LAB_DOMAIN        = ENV['LAB_DOMAIN']  || "yourlab.local"   # AD domain name
LAB_NETBIOS       = ENV['LAB_NETBIOS'] || "YOURLAB"         # NetBIOS domain name
LAB_NETWORK       = ENV['LAB_NETWORK'] || "192.168.56"      # VirtualBox host-only network prefix

# Topology is now derived from the active LAB_PROFILE's component list
# in the Vagrantfile (presence of rootca+issueca vs ca1 etc.). See
# vagrant/lib/lab_profile.rb and vagrant/profiles/*.yml.

# 2-letter prefix for log source names (e.g., "2T-DC1", "1T-CA1") to distinguish
# topologies in OpenSearch when running multiple labs simultaneously
LOG_PREFIX        = ENV['LOG_PREFIX'] || 'SL'  # was: TOPOLOGY-derived prefix

LAB_TIMEZONE       = ENV['LAB_TIMEZONE']       || 'Central Standard Time'
LAB_TIMEZONE_LINUX = ENV['LAB_TIMEZONE_LINUX']  || 'America/Chicago'
PWSH_VERSION       = ENV['PWSH_VERSION']        || '7.4.7'

#===============================================================================
# Credentials
#===============================================================================
ADMIN_PASSWORD    = "TenTowns00!"          # Domain/Local admin password
SAFE_MODE_PASSWORD = "TenTowns00!"         # AD DS Safe Mode password
SVC_PASSWORD      = "SvcPKI00!"            # PKI service account password (svc-ndes, svc-cep, svc-ces)

#===============================================================================
# VM Resource Defaults
#===============================================================================
VM_DEFAULTS = {
  dc: {
    memory: 4096,
    cpus: 2
  },
  ca: {
    memory: 4096,
    cpus: 2
  },
  web: {
    memory: 2048,
    cpus: 1
  },
  client: {
    memory: 4096,
    cpus: 2
  },
  manage: {
    memory: 8192,
    cpus: 4
  },
  wsus: {
    memory: 4096,
    cpus: 2
  },
  ejbca: {
    memory: 4096,
    cpus: 2
  },
  stepca: {
    memory: 2048,
    cpus: 1
  },
  hydra: {
    memory: 2048,
    cpus: 1
  },
  tomcat: {
    memory: 4096,
    cpus: 2
  },
  observe: {
    memory: 8192,
    cpus: 4
  },
  scanner: {
    memory: 4096,
    cpus: 2
  },
  apps: {
    memory: 8192,
    cpus: 4
  },
  acme: {
    memory: 1024,
    cpus: 1
  },
  sql: {
    memory: 6144,
    cpus: 2
  }
}

#===============================================================================
# Vagrant Box Images
#===============================================================================
# Default to upstream gusztavvargadr boxes; override to a locally-baked
# straylight/* box (built via packer/) to skip per-VM Ansible installs of
# PS7 + ADCS features + GA (the slow cold-build pain points).
# Set USE_STRAYLIGHT_BOXES=true to flip to baked boxes. There is no automatic
# fallback: if the straylight/* box isn't registered locally, `vagrant up`
# fails — run packer/build-images.sh first or unset the flag.
#
# Set WIN_SERVER_VERSION environment variable to switch versions:
#   export WIN_SERVER_VERSION=2022

USE_STRAYLIGHT_BOXES = ENV['USE_STRAYLIGHT_BOXES'] == 'true'

# Box freshness contract. When using locally-baked straylight/* boxes,
# packer/build-images.sh stamps each .box with a version (default UTC datestamp
# YYYY.MM.DD, or whatever BOX_VERSION= you passed) and registers it under that
# version. Pin a specific bake here so a stale local box can't silently satisfy
# `vagrant up` — set STRAYLIGHT_BOX_VERSION to the value build-images.sh printed.
# Leave unset to use whatever straylight/* box version is registered locally.
# Only applied to straylight/* boxes; upstream gusztavvargadr boxes carry their
# own published versions and are left to Vagrant's default resolution.
STRAYLIGHT_BOX_VERSION = ENV['STRAYLIGHT_BOX_VERSION']

BOX_WIN_SERVER_2022 = USE_STRAYLIGHT_BOXES ? "straylight/windows-server-2022" : "gusztavvargadr/windows-server-2022-standard"
BOX_WIN_SERVER_2025 = USE_STRAYLIGHT_BOXES ? "straylight/windows-server-2025" : "gusztavvargadr/windows-server-2025-standard"
# Server Core variants stay on upstream gusztavvargadr (sysprep'd).
# A locally-baked straylight/windows-server-2025-core was attempted but
# Server 2025 Core sysprep stalls silently in Packer after PnP driver
# generalization (no error, no shutdown).
# ADCS + sysprep is unsupported per Microsoft so we can't ship a baked
# Core image with ADCS preinstalled either. The InvalidSelectors race
# the bake was meant to fix is mitigated at runtime during provisioning.
BOX_WIN_SERVER_CORE_2022 = "gusztavvargadr/windows-server-2022-standard-core"
BOX_WIN_SERVER_CORE_2025 = "gusztavvargadr/windows-server-2025-standard-core"
BOX_WIN_11          = "gusztavvargadr/windows-11"

# Select Windows Server version (default: 2025)
WIN_SERVER_VERSION = ENV['WIN_SERVER_VERSION'] || '2025'

BOX_WIN_SERVER = case WIN_SERVER_VERSION
  when '2022' then BOX_WIN_SERVER_2022
  when '2025' then BOX_WIN_SERVER_2025
  else BOX_WIN_SERVER_2025
end

# Server Core for headless server roles (faster boot, no OOBE/desktop prompts).
BOX_WIN_SERVER_CORE = case WIN_SERVER_VERSION
  when '2022' then BOX_WIN_SERVER_CORE_2022
  when '2025' then BOX_WIN_SERVER_CORE_2025
  else BOX_WIN_SERVER_CORE_2025
end

BOX_WIN_CLIENT = BOX_WIN_11

# Linux boxes
BOX_LINUX_UBUNTU = "bento/ubuntu-22.04"

#===============================================================================
# IP Address Allocation
#===============================================================================
require_relative 'lib/topology'
# IP_ADDRESSES derived from topology.yml (single source of truth).
# Symbol keys preserve drop-in compatibility; hyphenated names become
# :"rootca-pqc". The `:web` key is retired in favour of :web1 (canonical).
# topology.yml's `network` is only the BASE/start prefix. LAB_NETWORK is set in
# the Vagrantfile from LabNetwork.for_lab (the dynamic /24 allocator) — or by the
# user/.env, which wins. Overriding Topology.network makes every Topology.ip() —
# IP_ADDRESSES, INVENTORY_HOSTS, render_inventory's lab_static_hosts — follow.
Topology.network = LAB_NETWORK
IP_ADDRESSES = Topology.ip_addresses

#===============================================================================
# PSFramework — local module cache
#===============================================================================
# Path to pre-downloaded PSFramework module (Save-Module -Name PSFramework -Path ...).
# Set PSF_PATH env var or place module in vagrant/resources/psframework/
# When present, installs from local VirtualBox shared folder (~instant)
# instead of PSGallery (~60s).
PSF_PATH = ENV['PSF_PATH'] || File.expand_path("resources/psframework", __dir__)
PSF_AVAILABLE = File.directory?(PSF_PATH) &&
                File.directory?(File.join(PSF_PATH, "PSFramework"))

#===============================================================================
# Software Cache — pre-staged installers for Windows VMs
#===============================================================================
# Path to pre-downloaded software (Winlogbeat ZIP, etc.).
# Set SOFTWARE_PATH env var or place files in vagrant/resources/software/
# When present, mounted as C:\Software on all Windows VMs (~instant install
# instead of downloading from the internet on each VM).
SOFTWARE_PATH = ENV['SOFTWARE_PATH'] || File.expand_path("resources/software", __dir__)
SOFTWARE_AVAILABLE = File.directory?(SOFTWARE_PATH) && !Dir.empty?(SOFTWARE_PATH)

#===============================================================================
# WSUS patch-DB caching — golden master + per-build working copy
#===============================================================================
# The WSUS SUSDB catalog + WsusContent binaries are cached in the software cache
# (resources/software/wsus-cache/, mounted as C:\Software\wsus-cache). The running
# WSUS works on its own D:\WSUS + WID copy; the cache is the R/O master.
#   WSUS_CACHE_RESTORE — restore working copy from the master at provision start.
#   WSUS_CACHE_CAPTURE — auto-capture SUSDB to the master at provision end.
# (WsusContent capture is an explicit step: scripts/cache-wsus.sh — content downloads
#  asynchronously and isn't complete at provision end.)
WSUS_CACHE_RESTORE = ENV['WSUS_CACHE_RESTORE'] != 'false'
WSUS_CACHE_CAPTURE = ENV['WSUS_CACHE_CAPTURE'] != 'false'

# Dedicated WSUS content disk size in GB. When > 0, a VDI data disk is
# created and attached at SATA port 1; WSUS stores content on D:\ instead
# of C:\. Set to 0 to keep content on the primary disk.
# To also resize the primary VMDK (one-time, VM must be powered off):
#   VBoxManage modifymedium disk <path-to-vmdk> --resize 204800
WSUS_CONTENT_DISK_GB = 200

#===============================================================================
# PKI Configuration
#===============================================================================
#===============================================================================
# EJBCA Configuration
#===============================================================================
EJBCA_CONFIG = {
  root_ca_name:    "EJBCA-Root-CA",
  issuing_ca_name: "EJBCA-Issuing-CA",
  organization:    LAB_NETBIOS,
  db_password:     "ejbca",
  token_password:  "foo123",
  image_tag:       "9.3.7",
}

#===============================================================================
# Smallstep step-ca Configuration
#===============================================================================
STEPCA_CONFIG = {
  ca_name:    "Smallstep-CA",
  password:   "stepcapass00!",
  image_tag:  "0.30.2",
}

#===============================================================================
# Ory Hydra Configuration
#===============================================================================
HYDRA_CONFIG = {
  image_tag:     "v2.2",
  db_password:   "hydra",
  system_secret: "YOURLABHYDRA-system-secret!",
}

#===============================================================================
# YubiHSM2 Configuration
#===============================================================================
# Mode: 'connector' (default) installs SDK + starts connector daemon.
#       'physical' also adds VirtualBox USB passthrough for a real YubiHSM2.
# Note: Yubico does not distribute a software simulator.
YUBIHSM_CONFIG = {
  mode:     ENV['YUBIHSM_MODE'] || 'connector',
  password: 'password',
}

#===============================================================================
# OpenSearch Stack Configuration
#===============================================================================
OPENSEARCH_CONFIG = {
  opensearch_tag: "2.15.0",
}

#===============================================================================
# Target Applications Configuration (APPS1)
#===============================================================================
APPS_CONFIG = {
  keycloak_tag:  "26.0",
  vault_tag:     "1.17",
  nifi_tag:      "2.0.0",
  gitea_tag:     "1.22",
  minio_tag:     "RELEASE.2025-09-07T16-13-09Z",
}

#===============================================================================
# Winlogbeat Configuration
#===============================================================================
WINLOGBEAT_CONFIG = {
  version: "8.17.0",
}

#===============================================================================
# Sysmon Configuration
#===============================================================================
SYSMON_CONFIG = {
  version: "15.15",
}

#===============================================================================
# Filebeat Configuration
#===============================================================================
FILEBEAT_CONFIG = {
  version: "8.17.0",
}

#===============================================================================
# Logging Control — set to false to disable logging roles during provisioning
#===============================================================================
LOGGING_ENABLED    = ENV['LOGGING_ENABLED']    != 'false'   # global kill switch
WINLOGBEAT_ENABLED = ENV['WINLOGBEAT_ENABLED'] != 'false'
FILEBEAT_ENABLED   = ENV['FILEBEAT_ENABLED']   != 'false'
SYSMON_ENABLED     = ENV['SYSMON_ENABLED']     != 'false'

PKI_CONFIG = {
  root_ca_name:     "#{LAB_NETBIOS}-Root-CA",
  issuing_ca_name:  "#{LAB_NETBIOS}-Issuing-CA",
  crl_url:          "http://pki.#{LAB_DOMAIN}/crl",
  aia_url:          "http://pki.#{LAB_DOMAIN}/aia",
  # The parallel ML-DSA hierarchy gets its own CDP/AIA namespace under
  # the same web1 host so the two hierarchies' CRLs/AIA certs never collide in
  # one directory. publish_ca_artifacts writes PQC artifacts into \crl\pqc +
  # \aia\pqc on the PKI$ share; web1 IIS serves them at these paths.
  crl_url_pqc:      "http://pki.#{LAB_DOMAIN}/crl/pqc",
  aia_url_pqc:      "http://pki.#{LAB_DOMAIN}/aia/pqc",
  validity_years: {
    root: 10,
    issuing: 5,
    end_entity: 2
  }
  # CRL validity is set per-CA in the role templates:
  #   roles/standalone_ca/templates/CAPolicy-standalone.inf.j2    (root: 26 weeks)
  #   roles/enterprise_ca/templates/CAPolicy.inf.j2               (one-tier root: 26 weeks)
  #   roles/subordinate_ca/templates/CAPolicy-subordinate.inf.j2  (issuing: 26 weeks)
  # Delta CRLs are 1 day. Cold-start gaps up to ~6 months are tolerated.
}
