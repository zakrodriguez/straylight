#!/usr/bin/env bash
# cache-software.sh — Download, verify, and cache software packages
# Reads scripts/software-manifest.yml, downloads missing files to
# resources/software/, validates SHA-256 checksums, and generates a
# CycloneDX 1.5 SBOM at resources/software/sbom.json.
set -euo pipefail

# ── Prerequisites ────────────────────────────────────────────────────
if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not found."
  echo "Install via:"
  echo "  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
  echo "  sudo chmod +x /usr/local/bin/yq"
  exit 1
fi

# ── Paths (relative to repo root) ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/scripts/software-manifest.yml"
CACHE_DIR="${REPO_ROOT}/resources/software"
SBOM="${CACHE_DIR}/sbom.json"
CHOCO_DIR="${CACHE_DIR}/choco"

if [[ ! -f "${MANIFEST}" ]]; then
  echo "ERROR: Manifest not found at ${MANIFEST}"
  exit 1
fi

mkdir -p "${CACHE_DIR}"
mkdir -p "${CHOCO_DIR}"

# ── Flags ────────────────────────────────────────────────────────────
FORCE=false
if [[ "${1:-}" == "--force" ]]; then
  FORCE=true
fi

# ── Download and verify ──────────────────────────────────────────────
FAILED=0

process_entry() {
  local platform="$1"
  local index="$2"

  local name version filename url sha256
  name=$(yq e ".${platform}[${index}].name" "${MANIFEST}")
  version=$(yq e ".${platform}[${index}].version" "${MANIFEST}")
  filename=$(yq e ".${platform}[${index}].filename" "${MANIFEST}")
  url=$(yq e ".${platform}[${index}].url" "${MANIFEST}")
  sha256=$(yq e ".${platform}[${index}].sha256 // \"\"" "${MANIFEST}")

  local filepath="${CACHE_DIR}/${filename}"

  # Allow nested filenames (e.g. "gnupg-cache/foo.tar.bz2") by ensuring parent dir exists.
  mkdir -p "$(dirname "${filepath}")"

  echo ""
  echo "==> ${name} ${version} (${platform})"

  # --force: remove existing file to trigger re-download
  if [[ "${FORCE}" == true ]] && [[ -f "${filepath}" ]]; then
    echo "    --force: removing existing ${filename}"
    rm -f "${filepath}"
  fi

  if [[ -f "${filepath}" ]]; then
    # File exists
    if [[ -n "${sha256}" ]]; then
      # Validate checksum
      local actual
      actual=$(sha256sum "${filepath}" | awk '{print $1}')
      if [[ "${actual}" == "${sha256}" ]]; then
        echo "    OK: checksum verified (${actual:0:16}...)"
        return 0
      else
        echo "    WARN: checksum mismatch — expected ${sha256:0:16}..., got ${actual:0:16}..."
        echo "    Re-downloading..."
        rm -f "${filepath}"
      fi
    else
      # No checksum in manifest — compute and write back
      local actual
      actual=$(sha256sum "${filepath}" | awk '{print $1}')
      echo "    Computed sha256: ${actual:0:16}..."
      yq -i ".${platform}[${index}].sha256 = \"${actual}\"" "${MANIFEST}"
      return 0
    fi
  fi

  # Download
  echo "    Downloading ${filename}..."
  if curl -fSL --progress-bar -o "${filepath}" "${url}"; then
    local actual
    actual=$(sha256sum "${filepath}" | awk '{print $1}')
    echo "    Downloaded. sha256: ${actual:0:16}..."

    if [[ -n "${sha256}" ]]; then
      # Re-download case — verify against expected
      if [[ "${actual}" != "${sha256}" ]]; then
        echo "    ERROR: re-downloaded file still fails checksum!"
        FAILED=$((FAILED + 1))
        return 1
      fi
    else
      # First download — write checksum back to manifest
      yq -i ".${platform}[${index}].sha256 = \"${actual}\"" "${MANIFEST}"
    fi
  else
    echo "    ERROR: download failed for ${filename}"
    FAILED=$((FAILED + 1))
    return 1
  fi
}

# Process windows entries
WIN_COUNT=$(yq e '.windows | length' "${MANIFEST}")
for ((i = 0; i < WIN_COUNT; i++)); do
  process_entry "windows" "${i}" || true
done

# Process linux entries
LINUX_COUNT=$(yq e '.linux | length' "${MANIFEST}")
for ((i = 0; i < LINUX_COUNT; i++)); do
  process_entry "linux" "${i}" || true
done

# Process choco entries (Windows host only)
CHOCO_COUNT=$(yq e '.choco | length' "${MANIFEST}")
if [[ "${CHOCO_COUNT}" -gt 0 && "${CHOCO_COUNT}" != "null" ]]; then
  if command -v choco &>/dev/null; then
    for ((i = 0; i < CHOCO_COUNT; i++)); do
      name=$(yq e ".choco[${i}].name" "${MANIFEST}")
      version=$(yq e ".choco[${i}].version" "${MANIFEST}")

      echo ""
      echo "==> ${name} ${version} (choco)"

      # Check if nupkg already exists (name.version.nupkg pattern)
      existing=$(find "${CHOCO_DIR}" -maxdepth 1 -iname "${name}.${version}.nupkg" 2>/dev/null | head -1)

      if [[ -n "${existing}" ]] && [[ "${FORCE}" == false ]]; then
        echo "    OK: ${name}.${version}.nupkg present"
        continue
      fi

      echo "    Downloading (internalize)..."
      if choco download "${name}" --version "${version}" --internalize \
           --output-directory "${CHOCO_DIR}" --no-progress 2>&1 | tail -1; then
        echo "    Downloaded ${name}.${version}.nupkg"
      else
        echo "    ERROR: choco download failed for ${name} ${version}"
        FAILED=$((FAILED + 1))
      fi
    done
  else
    echo ""
    echo "==> SKIP: choco section (Chocolatey not installed on this host)"
    echo "    Install Chocolatey or run this script from a Windows machine to cache choco packages."
  fi
fi

# ── Generate CycloneDX 1.5 SBOM ─────────────────────────────────────
echo ""
echo "==> Generating SBOM at ${SBOM}"

generate_sbom() {
  cat <<'HEADER'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {
    "component": {
      "type": "application",
      "name": "straylight",
      "description": "Vagrant-based Windows PKI lab software cache"
    }
  },
  "components": [
HEADER

  local first=true

  for platform in windows linux; do
    local count
    count=$(yq e ".${platform} | length" "${MANIFEST}")
    for ((i = 0; i < count; i++)); do
      local name version filename url sha256
      name=$(yq e ".${platform}[${i}].name" "${MANIFEST}")
      version=$(yq e ".${platform}[${i}].version" "${MANIFEST}")
      filename=$(yq e ".${platform}[${i}].filename" "${MANIFEST}")
      url=$(yq e ".${platform}[${i}].url" "${MANIFEST}")
      sha256=$(yq e ".${platform}[${i}].sha256 // \"\"" "${MANIFEST}")

      # Only include entries that have a checksum (i.e. have been downloaded)
      if [[ -z "${sha256}" ]]; then
        continue
      fi

      if [[ "${first}" == true ]]; then
        first=false
      else
        echo "    ,"
      fi

      cat <<ENTRY
    {
      "type": "application",
      "name": "${name}",
      "version": "${version}",
      "hashes": [{"alg": "SHA-256", "content": "${sha256}"}],
      "externalReferences": [{"type": "distribution", "url": "${url}"}],
      "properties": [
        {"name": "platform", "value": "${platform}"},
        {"name": "filename", "value": "${filename}"}
      ]
    }
ENTRY
    done
  done

  # Add choco entries to SBOM
  local choco_count
  choco_count=$(yq e ".choco | length" "${MANIFEST}")
  for ((i = 0; i < choco_count; i++)); do
    local name version
    name=$(yq e ".choco[${i}].name" "${MANIFEST}")
    version=$(yq e ".choco[${i}].version" "${MANIFEST}")

    # Only include if nupkg exists in cache
    local nupkg
    nupkg=$(find "${CHOCO_DIR}" -maxdepth 1 -iname "${name}.${version}.nupkg" 2>/dev/null | head -1)
    if [[ -z "${nupkg}" ]]; then
      continue
    fi

    if [[ "${first}" == true ]]; then
      first=false
    else
      echo "    ,"
    fi

    cat <<ENTRY
    {
      "type": "application",
      "name": "${name}",
      "version": "${version}",
      "purl": "pkg:chocolatey/${name}@${version}",
      "externalReferences": [{"type": "distribution", "url": "https://community.chocolatey.org/packages/${name}/${version}"}],
      "properties": [
        {"name": "platform", "value": "windows"},
        {"name": "installer", "value": "chocolatey"}
      ]
    }
ENTRY
  done

  cat <<'FOOTER'
  ]
}
FOOTER
}

generate_sbom > "${SBOM}"

echo "    SBOM written with $(yq e '[.windows[], .linux[]] | map(select(.sha256 != "")) | length' "${MANIFEST}") components"

# ── Summary ──────────────────────────────────────────────────────────
echo ""
if [[ "${FAILED}" -gt 0 ]]; then
  echo "DONE with ${FAILED} failure(s)."
  exit 1
else
  echo "DONE — all packages cached."
  exit 0
fi
