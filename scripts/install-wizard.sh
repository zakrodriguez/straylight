#!/bin/bash
# Straylight PKI Lab — Installation Wizard
# Single entry point: prereq install + lab config + deploy
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VAGRANT_DIR="$PROJECT_ROOT/vagrant"
ENV_FILE="$VAGRANT_DIR/.env"

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Defaults ──
OPT_PROFILE=""
OPT_DEPLOY=false
OPT_PREREQS_ONLY=false
OPT_DOMAIN=""
OPT_NETWORK=""
OPT_PASSWORD=""
INTERACTIVE=true

# ── Parse CLI args ──
# Detect host OS up-front so flag handlers + install code can branch on it.
detect_host_os() {
  local uname_s
  uname_s=$(uname -s)
  case "$uname_s" in
    Linux)            HOST_OS="linux" ;;
    Darwin)           HOST_OS="macos" ;;
    MINGW*|MSYS*|CYGWIN*) HOST_OS="windows" ;;
    *)                HOST_OS="unknown" ;;
  esac
  if [[ "$HOST_OS" == "linux" ]] && command -v lsb_release &>/dev/null; then
    HOST_OS_VARIANT=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]')
  fi
}
detect_host_os

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-supported-hosts)
      cat <<EOF
Supported host operating systems for straylight install-wizard.sh:

  Ubuntu 22.04+        Supported, tested baseline. Full apt-based prereq
                       install (VirtualBox + Vagrant + Ansible via official
                       repos). Detected via: uname -s = Linux + lsb_release = Ubuntu.

  macOS / Windows      Not supported. Both were evaluated (2026-06-24) and
                       declined — no VirtualBox Apple-Silicon support, and
                       WSL2 -> host-only networking is unguaranteed. Run
                       straylight inside a Linux VM or on a remote Linux
                       host. See ARCHITECTURE.md for the rationale.

Detected on this host: $HOST_OS${HOST_OS_VARIANT:+ ($HOST_OS_VARIANT)}
EOF
      exit 0
      ;;
    --profile)       OPT_PROFILE="$2"; INTERACTIVE=false; shift 2 ;;
    --domain)        OPT_DOMAIN="$2"; shift 2 ;;
    --network)       OPT_NETWORK="$2"; shift 2 ;;
    --password)      OPT_PASSWORD="$2"; shift 2 ;;
    --deploy)        OPT_DEPLOY=true; shift ;;
    --prereqs-only)  OPT_PREREQS_ONLY=true; shift ;;
    --all)           OPT_PROFILE="full"; INTERACTIVE=false; shift ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Interactive (default):"
      echo "  $0                                    Run interactive wizard"
      echo ""
      echo "Non-interactive:"
      echo "  $0 --profile ad-cs-two-tier --deploy"
      echo "  $0 --profile pqc-linux --deploy"
      echo "  $0 --prereqs-only                     Install prereqs only"
      echo "  $0 --all --deploy                     Full lab, start immediately"
      echo ""
      echo "Options:"
      echo "  --profile NAME     Lab profile from vagrant/profiles/*.yml"
      echo "                     e.g. core (default), ad-cs-one-tier,"
      echo "                     ad-cs-two-tier, ad-cs-minimal, pqc-linux,"
      echo "                     pqc-full, observability, cbom-pipeline, full"
      echo "  --domain FQDN      Lab domain (default: yourlab.local)"
      echo "  --network PREFIX   Pin ALL labs to one /24 prefix (any value EXCEPT"
      echo "                     the base 192.168.56, which is treated as the"
      echo "                     default). Default: each lab is dynamically"
      echo "                     allocated its own /24 from 192.168.56 up."
      echo "  --password PASS    Admin password (default: TenTowns00!)"
      echo "  --deploy           Start deployment after config"
      echo "  --prereqs-only     Install prerequisites, skip config"
      echo "  --all              Alias for --profile full"
      echo "  --list-supported-hosts"
      echo "                     Show host OS support matrix and detected host"
      echo ""
      echo "Run 'bash vagrant/up.sh --list-profiles' for the full catalog."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ──
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
log()  { printf "${CYAN}[wizard]${NC} %s\n" "$1"; }

prompt() {
  local var_name=$1 prompt_text=$2 default=$3
  if [[ "$INTERACTIVE" == true ]]; then
    printf "${GREEN}  %s ${DIM}[%s]${NC}: " "$prompt_text" "$default"
    read -r input
    eval "$var_name='${input:-$default}'"
  else
    eval "$var_name='${!var_name:-$default}'"
  fi
}

prompt_choice() {
  local var_name=$1 prompt_text=$2 default=$3
  shift 3
  if [[ "$INTERACTIVE" == true ]]; then
    echo ""
    printf "  ${GREEN}%s${NC}\n" "$prompt_text"
    local i=1
    for opt in "$@"; do
      printf "    ${BOLD}%d)${NC} %s\n" "$i" "$opt"
      ((i++))
    done
    printf "  ${GREEN}Choice ${DIM}[%s]${NC}: " "$default"
    read -r input
    eval "$var_name='${input:-$default}'"
  else
    eval "$var_name='${!var_name:-$default}'"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# Phase 1: Prereq Detection + Install
# ═══════════════════════════════════════════════════════════════════════
check_prereqs() {
  log "Phase 1: Checking prerequisites..."
  echo ""

  local missing_sudo=()
  local missing_user=()

  # Python 3.10+
  if python3 --version 2>/dev/null | grep -qE '3\.(1[0-9]|[2-9][0-9])'; then
    ok "Python $(python3 --version 2>&1 | awk '{print $2}')"
  else
    fail "Python 3.10+ not found"
    missing_sudo+=(python3)
  fi

  # git
  if command -v git &>/dev/null; then
    ok "git $(git --version | awk '{print $3}')"
  else
    fail "git not found"
    missing_sudo+=(git)
  fi

  # sshpass
  if command -v sshpass &>/dev/null; then
    ok "sshpass"
  else
    fail "sshpass not found"
    missing_sudo+=(sshpass)
  fi

  # VirtualBox
  if command -v vboxmanage &>/dev/null; then
    ok "VirtualBox $(vboxmanage --version)"
  else
    fail "VirtualBox not found"
    missing_sudo+=(virtualbox)
  fi

  # VBox Extension Pack
  if vboxmanage list extpacks 2>/dev/null | grep -q "Oracle VM VirtualBox Extension Pack"; then
    ok "VirtualBox Extension Pack"
  else
    if command -v vboxmanage &>/dev/null; then
      fail "VirtualBox Extension Pack not installed"
      missing_sudo+=(vbox-extpack)
    fi
  fi

  # Vagrant
  if command -v vagrant &>/dev/null; then
    ok "Vagrant $(vagrant --version 2>&1 | awk '{print $2}')"
  else
    fail "Vagrant not found"
    missing_sudo+=(vagrant)
  fi

  # vagrant-vbguest plugin
  if vagrant plugin list 2>/dev/null | grep -q vagrant-vbguest; then
    ok "vagrant-vbguest plugin"
  else
    fail "vagrant-vbguest plugin not installed"
    missing_user+=(vagrant-vbguest)
  fi

  # Ansible
  if command -v ansible &>/dev/null; then
    ok "Ansible $(ansible --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  else
    fail "Ansible not found"
    missing_user+=(ansible)
  fi

  # Ansible collections
  local req_file="$VAGRANT_DIR/ansible/requirements.yml"
  if [[ -f "$req_file" ]] && ansible-galaxy collection list 2>/dev/null | grep -q microsoft.ad; then
    ok "Ansible collections (microsoft.ad, etc.)"
  else
    fail "Ansible collections not installed"
    missing_user+=(ansible-collections)
  fi

  # Docker (for cbomkit-theia CBOM scanner)
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    ok "Docker $(docker --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  else
    fail "Docker not found or not running"
    missing_sudo+=(docker)
  fi

  # cbomkit-theia (CBOM scanner — binary or Docker image)
  if command -v cbomkit-theia &>/dev/null; then
    ok "cbomkit-theia (binary)"
  elif docker image inspect ghcr.io/ibm/cbomkit-theia:latest &>/dev/null 2>&1; then
    ok "cbomkit-theia (Docker image)"
  else
    fail "cbomkit-theia not found (binary or Docker image)"
    missing_user+=(cbomkit-theia)
  fi

  echo ""

  # Install missing
  if [[ ${#missing_sudo[@]} -eq 0 && ${#missing_user[@]} -eq 0 ]]; then
    log "All prerequisites satisfied!"
    return 0
  fi

  log "Missing prerequisites detected."
  echo ""

  # System packages (need sudo)
  if [[ ${#missing_sudo[@]} -gt 0 ]]; then
    printf "  ${YELLOW}System packages needed (requires sudo):${NC}\n"
    for pkg in "${missing_sudo[@]}"; do
      printf "    - %s\n" "$pkg"
    done
    echo ""

    if [[ "$INTERACTIVE" == true ]]; then
      printf "  ${GREEN}Install system packages? [Y/n]:${NC} "
      read -r yn
      [[ "${yn,,}" == "n" ]] && { warn "Skipping system packages — some features will not work."; } || install_system_packages "${missing_sudo[@]}"
    else
      install_system_packages "${missing_sudo[@]}"
    fi
  fi

  # User-space packages
  if [[ ${#missing_user[@]} -gt 0 ]]; then
    for pkg in "${missing_user[@]}"; do
      case "$pkg" in
        vagrant-vbguest)
          log "Installing vagrant-vbguest plugin..."
          vagrant plugin install vagrant-vbguest
          ok "vagrant-vbguest installed"
          ;;
        ansible)
          log "Installing Ansible..."
          if command -v pipx &>/dev/null; then
            pipx install ansible
          elif command -v pip3 &>/dev/null; then
            pip3 install --user ansible
          else
            warn "Cannot install Ansible — install pipx or pip3 first"
          fi
          ok "Ansible installed"
          ;;
        ansible-collections)
          log "Installing Ansible collections..."
          ansible-galaxy collection install -r "$VAGRANT_DIR/ansible/requirements.yml"
          ok "Ansible collections installed"
          ;;
        cbomkit-theia)
          log "Pulling cbomkit-theia Docker image..."
          docker pull ghcr.io/ibm/cbomkit-theia:latest
          ok "cbomkit-theia Docker image pulled"
          ;;
      esac
    done
  fi

  echo ""
}

install_system_packages() {
  local packages=("$@")

  case "$HOST_OS" in
    linux)
      install_system_packages_apt "${packages[@]}"
      ;;
    macos)
      fail "macOS host not supported (evaluated 2026-06-24 and declined; no VirtualBox Apple-Silicon support — see ARCHITECTURE.md)."
      warn "Run Straylight inside a Linux VM or on a remote Linux host."
      exit 1
      ;;
    windows)
      fail "Windows host not supported (evaluated 2026-06-24 and declined; WSL2 -> host-only networking is unguaranteed — see ARCHITECTURE.md)."
      warn "Run Straylight inside a Linux VM or on a remote Linux host."
      exit 1
      ;;
    *)
      fail "Unsupported host OS: $(uname -s)."
      warn "See: $0 --list-supported-hosts"
      exit 1
      ;;
  esac
}

install_system_packages_apt() {
  local packages=("$@")
  local apt_packages=()

  # Detect Ubuntu codename for repos
  local codename
  codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

  for pkg in "${packages[@]}"; do
    case "$pkg" in
      python3)    apt_packages+=(python3 python3-pip python3-venv pipx) ;;
      git)        apt_packages+=(git) ;;
      sshpass)    apt_packages+=(sshpass) ;;
      virtualbox)
        # Add Oracle VirtualBox repo
        log "Adding VirtualBox repository..."
        wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $codename contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list > /dev/null
        apt_packages+=(virtualbox-7.1)
        ;;
      vagrant)
        # Add HashiCorp repo
        log "Adding HashiCorp repository..."
        wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $codename main" | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
        apt_packages+=(vagrant)
        ;;
      vbox-extpack)
        # Install after VirtualBox
        ;;
    esac
  done

  if [[ ${#apt_packages[@]} -gt 0 ]]; then
    log "Installing: ${apt_packages[*]}..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${apt_packages[@]}"
  fi

  # VBox Extension Pack (needs VirtualBox installed first)
  for pkg in "${packages[@]}"; do
    if [[ "$pkg" == "vbox-extpack" ]] && command -v vboxmanage &>/dev/null; then
      local vbox_ver
      vbox_ver=$(vboxmanage --version | cut -d'r' -f1)
      log "Installing VirtualBox Extension Pack ${vbox_ver}..."
      local url="https://download.virtualbox.org/virtualbox/${vbox_ver}/Oracle_VM_VirtualBox_Extension_Pack-${vbox_ver}.vbox-extpack"
      wget -q -O /tmp/vbox-extpack.vbox-extpack "$url" 2>/dev/null && \
        echo "y" | sudo vboxmanage extpack install --replace /tmp/vbox-extpack.vbox-extpack 2>/dev/null && \
        rm -f /tmp/vbox-extpack.vbox-extpack && \
        ok "Extension Pack installed" || \
        warn "Extension Pack install failed — install manually"
    fi
  done

  # Add user to vboxusers if VirtualBox was just installed
  for pkg in "${packages[@]}"; do
    if [[ "$pkg" == "virtualbox" ]]; then
      sudo usermod -aG vboxusers "$(whoami)" 2>/dev/null || true
      warn "Added $(whoami) to vboxusers group — log out and back in for this to take effect"
    fi
  done
}


# ═══════════════════════════════════════════════════════════════════════
# Phase 2: Lab Configuration
# ═══════════════════════════════════════════════════════════════════════
collect_config() {
  if [[ "$OPT_PREREQS_ONLY" == true ]]; then
    return
  fi

  log "Phase 2: Lab configuration..."
  echo ""

  # Domain
  local domain="${OPT_DOMAIN:-}"
  prompt domain "Active Directory domain name" "yourlab.local"
  LAB_DOMAIN="$domain"
  LAB_NETBIOS=$(echo "$LAB_DOMAIN" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')

  # Network
  local network="${OPT_NETWORK:-}"
  prompt network "Network prefix (first 3 octets)" "192.168.56"
  LAB_NETWORK="$network"

  # Password
  local password="${OPT_PASSWORD:-}"
  prompt password "Administrator password" "TenTowns00!"
  ADMIN_PASSWORD="$password"

  # Profile — single axis now. Replaces the old separate topology+profile prompts.
  local profile="${OPT_PROFILE:-}"
  if [[ -z "$profile" ]]; then
    prompt_choice profile "Lab profile:" "1" \
      "core — DC + CA + IIS + RSAT workstation (default, ~15 min)" \
      "ad-cs-two-tier — Offline root + Enterprise Issuing CA (~25 min)" \
      "ad-cs-minimal — Smallest viable AD CS demo, 3 GB RAM (~30 min)" \
      "pqc-linux — PQC migration demo without Windows / AD CS (~10 min)" \
      "cbom-pipeline — Three CAs + scanner + observe for full CBOM pipeline" \
      "full — Full classical stack (18 VMs, ~60 min)"
    case "$profile" in
      2) profile="ad-cs-two-tier" ;;
      3) profile="ad-cs-minimal" ;;
      4) profile="pqc-linux" ;;
      5) profile="cbom-pipeline" ;;
      6) profile="full" ;;
      *) profile="core" ;;
    esac
  fi
  LAB_PROFILE="$profile"

  # Validate the profile exists.
  if [[ ! -f "$VAGRANT_DIR/profiles/$LAB_PROFILE.yml" ]]; then
    fail "Profile '$LAB_PROFILE' not found in $VAGRANT_DIR/profiles/"
    echo "  Available: $(cd "$VAGRANT_DIR/profiles" && ls *.yml | sed 's/\.yml//' | tr '\n' ' ')"
    exit 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# Phase 3: Write .env + Summary
# ═══════════════════════════════════════════════════════════════════════
write_env() {
  if [[ "$OPT_PREREQS_ONLY" == true ]]; then
    return
  fi

  log "Phase 3: Writing configuration..."
  echo ""

  cat > "$ENV_FILE" << EOF
# Generated by install-wizard.sh on $(date '+%Y-%m-%d %H:%M:%S')
LAB_PROFILE=$LAB_PROFILE
LAB_DOMAIN=$LAB_DOMAIN
LAB_NETBIOS=$LAB_NETBIOS
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
  # Only pin LAB_NETWORK when the user chose a NON-base prefix. Writing the base
  # .56 here would (via the Vagrantfile's LabNetwork.for_lab fallback being
  # skipped when LAB_NETWORK is already set) override every lab's dynamically
  # allocated /24 and silently reintroduce the multi-profile IP collision. Omit
  # it so per-lab dynamic allocation governs. (This `cat >` also rewrites .env on
  # re-run, so a legacy LAB_NETWORK=192.168.56 line from an old wizard is dropped.)
  if [[ -n "$LAB_NETWORK" && "$LAB_NETWORK" != "192.168.56" ]]; then
    echo "LAB_NETWORK=$LAB_NETWORK" >> "$ENV_FILE"
  fi

  ok "Configuration written to vagrant/.env"
  echo ""

  # Summary
  printf "  ${BOLD}%-20s${NC} %s\n" "Profile:" "$LAB_PROFILE"
  printf "  ${BOLD}%-20s${NC} %s\n" "Domain:" "$LAB_DOMAIN"
  printf "  ${BOLD}%-20s${NC} %s\n" "NetBIOS:" "$LAB_NETBIOS"
  if [[ -n "$LAB_NETWORK" && "$LAB_NETWORK" != "192.168.56" ]]; then
    printf "  ${BOLD}%-20s${NC} %s\n" "Network:" "$LAB_NETWORK.0/24 (pinned for ALL profiles)"
  else
    printf "  ${BOLD}%-20s${NC} %s\n" "Network:" "per-profile /24 (base 192.168.56; each profile on its own subnet)"
  fi
  printf "  ${BOLD}%-20s${NC} %s\n" "Admin password:" "$ADMIN_PASSWORD"
  echo ""

  # VM table — sourced directly from the profile YAML
  printf "  ${BOLD}VMs to deploy:${NC}\n"
  if command -v ruby >/dev/null 2>&1; then
    ruby -I "$VAGRANT_DIR/lib" -r lab_profile -e '
      ENV["LAB_PROFILE"] = "'"$LAB_PROFILE"'"
      p = LabProfile.resolve
      p[:components].each { |c| puts "    #{c}" }
    '
  else
    grep "^  -" "$VAGRANT_DIR/profiles/$LAB_PROFILE.yml" | sed 's/^  - / /' | head -20
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# Phase 4: Deploy
# ═══════════════════════════════════════════════════════════════════════
deploy() {
  if [[ "$OPT_PREREQS_ONLY" == true ]]; then
    log "Prerequisites installed. Run the wizard again to configure and deploy."
    exit 0
  fi

  local do_deploy="$OPT_DEPLOY"
  if [[ "$INTERACTIVE" == true && "$do_deploy" != true ]]; then
    printf "  ${GREEN}Start deployment now? [Y/n]:${NC} "
    read -r yn
    [[ "${yn,,}" != "n" ]] && do_deploy=true
  fi

  if [[ "$do_deploy" == true ]]; then
    log "Phase 4: Deploying lab..."
    echo ""
    cd "$VAGRANT_DIR"
    if [[ "$LAB_PROFILE" == "full" ]]; then
      exec bash up.sh --all
    else
      exec bash up.sh
    fi
  else
    echo ""
    log "Configuration saved to vagrant/.env"
    echo ""
    echo "  To deploy:"
    echo "    cd vagrant && bash up.sh"
    echo ""
    echo "  To deploy with all optional VMs:"
    echo "    cd vagrant && bash up.sh --all"
    echo ""
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════
main() {
  if [[ "$INTERACTIVE" == true ]]; then
    clear
    echo -e "${CYAN}"
    echo "  ╔═════════════════════════════════════════════════════╗"
    echo "  ║         STRAYLIGHT PKI LAB — INSTALL WIZARD        ║"
    echo "  ╚═════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  This wizard will install prerequisites, configure your"
    echo "  lab, and optionally start the deployment."
    echo ""
    echo -e "  ${DIM}Press Enter to accept defaults shown in [brackets].${NC}"
    echo ""
  fi

  check_prereqs
  collect_config
  write_env
  deploy
}

main "$@"
