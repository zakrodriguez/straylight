#!/usr/bin/env bash
# Packer Build Script for Windows Server Images
# Usage: ./build-images.sh [2022|2025|all]
#
# Both versions build from ONE parameterized template
# (windows/windows-server.pkr.hcl) selected via -var win_version=<ver>, sharing
# a single Autounattend.xml and the same lab-bake provisioning layer (PS7 +
# ADCS features + software cache). 2025 is the lab's canonical target — it's
# what the CA VMs run in the Vagrantfile. 2022 is for cross-version testing.
#
# Box freshness contract: each build stamps the .box with a version
# (default: UTC datestamp YYYY.MM.DD, override via BOX_VERSION=...). The box is
# registered with that version so two rebuilds no longer silently overwrite
# each other under an identical name+version, and consumers can pin a known
# bake via `config.vm.box_version` in vagrant/config.rb.
#
# ##########################################################################
# # DO NOT PUBLISH BOXES BUILT BY THIS SCRIPT.                             #
# #                                                                       #
# # The resulting .box files contain the known vagrant:vagrant credential  #
# # pair (and any other lab defaults baked by the Ansible roles). They are #
# # safe for local development use only. They MUST NOT be uploaded to a    #
# # shared registry (Vagrant Cloud, internal Artifactory, S3, etc.)        #
# # without first rebuilding with PACKER_BUILD_FOR_PUBLISH=1 and following #
# # the hardening checklist in packer/README.md (rotate Administrator pw,  #
# # sysprep generalize /oobe, audit the image).                           #
# ##########################################################################

set -euo pipefail

# Runtime guard + publish-mode wiring.
#
# Default path (PACKER_BUILD_FOR_PUBLISH unset or != 1): warn loudly that the
# .box is local-use-only, then build with publish_mode=false. Nothing else
# changes — the lab daily-driver path is byte-for-byte the same as before.
#
# Publish path (PACKER_BUILD_FOR_PUBLISH=1): pass publish_mode=true into the
# HCL config. That:
#   - flips cleanup.ps1's PACKER_BUILD_FOR_PUBLISH env to "1" so its opt-in
#     branch runs (random pw + publish-unattend.xml + sysprep /generalize)
#   - empties shutdown_command (sysprep handles shutdown itself)
#   - swaps the vagrant post-processor template to
#     vagrantfile-windows-publish.template (placeholder winrm.password line
#     instead of the hardcoded "vagrant" string)
PUBLISH_MODE_FLAG="false"
if [ "${PACKER_BUILD_FOR_PUBLISH:-0}" != "1" ]; then
    cat <<'BANNER' >&2
==========================================================================
 WARNING: building a LOCAL-USE-ONLY image.

 The .box produced by this script ships with the vagrant:vagrant default
 credentials and lab-friendly defaults. Do NOT push it to Vagrant Cloud
 or any other shared registry.

 To produce a publish-candidate image, re-run with:
     PACKER_BUILD_FOR_PUBLISH=1 ./build-images.sh ...
 (rotates Administrator pw + sysprep /generalize /oobe — see README).
==========================================================================
BANNER
else
    PUBLISH_MODE_FLAG="true"
    cat <<'BANNER' >&2
==========================================================================
 PUBLISH MODE: building a sysprep-generalized image.

 At the END of the build, cleanup.ps1 will:
   - mint a single-use 20-char Administrator password
   - print it to THIS LOG (search for "ONE-TIME ADMINISTRATOR PASSWORD")
   - write C:\Windows\Panther\publish-unattend.xml
   - run sysprep /generalize /oobe /shutdown

 The resulting .box ships with NO known admin credential. The consumer
 will walk through Windows OOBE on first boot and set their own pw.
 Adds ~5-10 minutes to the build for sysprep + generalize.
==========================================================================
BANNER
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ISO locations — override via env if your ISOs live elsewhere
ISO_2022="${ISO_2022:-$HOME/straylight/isos/windows-server-2022.iso}"
ISO_2025="${ISO_2025:-$HOME/straylight/isos/windows-server-2025.iso}"

# ISO checksums (SHA256) — populate after downloading.
# Quick way: sha256sum "$ISO_2025" | awk '{print "sha256:"$1}'
# If left as the placeholder, build_image() computes + uses the live sha256
# (warns) so first build still works.
CHECKSUM_2022="${CHECKSUM_2022:-sha256:REPLACE_WITH_ACTUAL_CHECKSUM}"
CHECKSUM_2025="${CHECKSUM_2025:-sha256:REPLACE_WITH_ACTUAL_CHECKSUM}"

# Lab-bake parameters
PWSH_VERSION="${PWSH_VERSION:-7.4.7}"

# Box freshness contract. Default to a UTC datestamp so every build
# is distinguishable; pin a deliberate value with BOX_VERSION=YYYY.MM.DD (or
# any 3-part numeric version) for a reproducible publish. Must be 3-part
# numeric for Vagrant box_version compatibility (leading zeros stripped).
BOX_VERSION="${BOX_VERSION:-$(date -u +%Y.%-m.%-d)}"

build_image() {
    local version=$1
    # Bash vars can't contain dashes; "2025-core" lookups go to ISO_2025_core.
    # If that's unset, fall back to the base version ("2025-core" -> "2025")
    # so Core variants reuse the same upstream ISO + checksum.
    local var_suffix="${version//-/_}"
    local base_version="${version%%-*}"
    local iso_var="ISO_${var_suffix}"
    local checksum_var="CHECKSUM_${var_suffix}"
    local iso_path="${!iso_var:-}"
    local checksum="${!checksum_var:-}"
    if [ -z "$iso_path" ] && [ "$var_suffix" != "$base_version" ]; then
        iso_var="ISO_${base_version}"
        checksum_var="CHECKSUM_${base_version}"
        iso_path="${!iso_var:-}"
        checksum="${!checksum_var:-}"
        echo "  Using ISO/checksum from $iso_var (base for $version)"
    fi

    echo "=========================================="
    echo "Building Windows Server $version (HCL2 + lab-bake)..."
    echo "  ISO:         $iso_path"
    echo "  PowerShell:  $PWSH_VERSION"
    echo "  Box version: $BOX_VERSION"
    echo "=========================================="

    if [[ ! -f "$iso_path" ]]; then
        echo "ERROR: ISO not found at $iso_path"
        echo "Download Server $version Evaluation from https://www.microsoft.com/en-us/evalcenter/"
        echo "and place it there (or set $iso_var=<path>)"
        return 1
    fi

    if [[ "$checksum" == *REPLACE_WITH_ACTUAL_CHECKSUM* ]]; then
        local computed
        computed=$(sha256sum "$iso_path" | awk '{print $1}')
        echo "WARN: $checksum_var not set; computed sha256 = $computed"
        echo "      Pin it: export $checksum_var=sha256:$computed"
        checksum="sha256:$computed"
    fi

    pushd "windows" >/dev/null

    packer init "windows-server.pkr.hcl"
    packer build \
        -var "win_version=$version" \
        -var "box_version=$BOX_VERSION" \
        -var "iso_url=$iso_path" \
        -var "iso_checksum=$checksum" \
        -var "pwsh_version=$PWSH_VERSION" \
        -var "publish_mode=$PUBLISH_MODE_FLAG" \
        "windows-server.pkr.hcl"

    local boxfile="./box/straylight-windows-server-$version-$BOX_VERSION.box"

    # Integrity check: gzip stream + VMDK readability. The retry 7 build
    # produced a .box whose VMDK had a zeroed-out streamOptimized footer
    # (VBoxManage rejected it with VERR_ZIP_CORRUPTED) AND whose outer gzip
    # failed CRC at end-of-stream. Catch that here before `vagrant box add`
    # so we don't waste cycles registering an unusable box.
    echo ""
    echo "Verifying $boxfile integrity..."
    if ! gzip -t "$boxfile" 2>/dev/null; then
        echo "ERROR: $boxfile gzip CRC check FAILED"
        return 2
    fi
    echo "  [ok] gzip -t passes"

    # Extract VMDK + run qemu-img check on it (cheap, doesn't decompress payload)
    local tmpvmdk
    tmpvmdk=$(mktemp --suffix=.vmdk)
    if ! tar -xzOf "$boxfile" "straylight-windows-server-$version-disk001.vmdk" > "$tmpvmdk" 2>/dev/null; then
        echo "ERROR: tar extraction of VMDK from $boxfile FAILED"
        rm -f "$tmpvmdk"
        return 3
    fi
    if ! qemu-img info "$tmpvmdk" >/dev/null 2>&1; then
        echo "ERROR: qemu-img info on extracted VMDK FAILED"
        rm -f "$tmpvmdk"
        return 4
    fi
    # Dry-run import via clonemedium — catches the corrupted streamOptimized
    # footer that breaks vagrant up. ~5-10s overhead per build.
    local testvdi
    testvdi=$(mktemp --suffix=.vdi -u)
    if ! VBoxManage clonemedium disk "$tmpvmdk" "$testvdi" --format VDI >/dev/null 2>&1; then
        VBoxManage closemedium disk "$testvdi" 2>/dev/null
        VBoxManage closemedium disk "$tmpvmdk" 2>/dev/null
        rm -f "$tmpvmdk" "$testvdi"
        echo "ERROR: VBoxManage clonemedium dry-run FAILED — VMDK is corrupt"
        return 5
    fi
    VBoxManage closemedium disk "$testvdi" --delete 2>/dev/null
    VBoxManage closemedium disk "$tmpvmdk" 2>/dev/null
    rm -f "$tmpvmdk"
    echo "  [ok] VMDK passes VBoxManage clonemedium dry-run"

    vagrant box add --force --box-version "$BOX_VERSION" \
        "straylight/windows-server-$version" "$boxfile"

    popd >/dev/null

    echo ""
    echo "Windows Server $version image built and added to Vagrant as version $BOX_VERSION."
}

case "${1:-2025}" in
    2022|2025)
        build_image "$1"
        ;;
    all)
        build_image 2025
        build_image 2022 || echo "2022 build failed -- continuing"
        ;;
    *)
        echo "Usage: $0 [2022|2025|all]"
        echo "  Default:    2025 (lab canonical Desktop variant)"
        echo "  Note: Server Core variants stay on upstream gusztavvargadr boxes —"
        echo "        Server 2025 Core sysprep stalls in Packer (see config.rb)."
        exit 1
        ;;
esac

echo ""
echo "Build complete!"
echo ""
echo "To use built boxes, in vagrant/config.rb set:"
echo "  USE_STRAYLIGHT_BOXES=true   (env or edit) — flips to the straylight/* boxes"
echo "To PIN this exact bake (recommended for reproducibility), also set:"
echo "  export STRAYLIGHT_BOX_VERSION=$BOX_VERSION   # consumed by config.rb -> config.vm.box_version"
