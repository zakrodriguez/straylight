#!/usr/bin/env bash
# Shared helpers for az700.sh. Sourced, not executed.
#
# Safety model: every destructive operation matches resource groups by BOTH
# name prefix (rg-straylight-az700-) AND tag (track=az700) — nothing outside
# the track can ever be touched, whatever else lives in the subscription.

AZ700_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AZURE_DIR="$(cd "${AZ700_LIB_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${AZURE_DIR}/.." && pwd)"
CLAIMS_FILE="${HOME}/.straylight/az700-deployments.json"
RG_PREFIX="rg-straylight-az700-"

az700::die() {
  echo "az700: ERROR: $*" >&2
  exit 1
}

az700::warn() {
  echo "az700: $*" >&2
}

az700::require_az() {
  command -v az >/dev/null 2>&1 ||
    az700::die "az CLI not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
}

az700::require_login() {
  az account show >/dev/null 2>&1 ||
    az700::die "not logged in. Run: az login --use-device-code"
}

# Read AZURE_SUBSCRIPTION_ID / AZ700_LOCATION from vagrant/.env without
# sourcing it (the file may hold unrelated lab settings).
az700::load_env() {
  local env_file="${REPO_ROOT}/vagrant/.env"
  # `|| true` inside each substitution: a key absent from .env exits grep 1,
  # which pipefail would otherwise propagate through the assignment and kill
  # the script under set -e before the defaults below can apply.
  if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" && -f "${env_file}" ]]; then
    AZURE_SUBSCRIPTION_ID="$(grep -E '^AZURE_SUBSCRIPTION_ID=' "${env_file}" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  fi
  if [[ -z "${AZ700_LOCATION:-}" && -f "${env_file}" ]]; then
    AZ700_LOCATION="$(grep -E '^AZ700_LOCATION=' "${env_file}" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  fi
}

# Refuse to run against the wrong subscription. Pin via AZURE_SUBSCRIPTION_ID
# (env or vagrant/.env); with no pin, show the active subscription and confirm.
az700::require_subscription() {
  local current_id current_name
  current_id="$(az account show --query id -o tsv)"
  current_name="$(az account show --query name -o tsv)"
  if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    [[ "${current_id}" == "${AZURE_SUBSCRIPTION_ID}" ]] ||
      az700::die "active subscription ${current_name} (${current_id}) does not match the AZURE_SUBSCRIPTION_ID pin. Run: az account set --subscription ${AZURE_SUBSCRIPTION_ID}"
  else
    az700::warn "no AZURE_SUBSCRIPTION_ID pin set (vagrant/.env) — active subscription: ${current_name} (${current_id})"
    az700::confirm "Use this subscription?"
  fi
}

az700::confirm() {
  [[ "${AZ700_YES:-0}" == "1" ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "${reply}" == "y" || "${reply}" == "Y" ]] || az700::die "aborted"
}

az700::location() {
  echo "${AZ700_LOCATION:-centralus}"
}

az700::rg_name() {
  echo "${RG_PREFIX}$1"
}

# Guard for destructive ops: the RG must carry the track tag, not just the name.
az700::assert_az700_rg() {
  local track
  track="$(az group show --name "$1" --query 'tags.track' -o tsv 2>/dev/null)" ||
    az700::die "resource group $1 not found"
  [[ "${track}" == "az700" ]] ||
    az700::die "resource group $1 is not tagged track=az700 — refusing to touch it"
}

# All track RGs (name prefix AND tag), as TSV: name<TAB>created-tag.
az700::list_rgs() {
  az group list --tag track=az700 \
    --query "[?starts_with(name, '${RG_PREFIX}')].[name, tags.created]" -o tsv
}

az700::claim_add() {
  python3 - "$1" "$2" <<'PY'
import json, os, sys, time
path = os.path.expanduser("~/.straylight/az700-deployments.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
claims = {}
if os.path.exists(path):
    with open(path) as fh:
        claims = json.load(fh)
claims[sys.argv[1]] = {"rg": sys.argv[2], "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
with open(path, "w") as fh:
    json.dump(claims, fh, indent=2)
PY
}

az700::claim_remove() {
  python3 - "$1" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.straylight/az700-deployments.json")
if os.path.exists(path):
    with open(path) as fh:
        claims = json.load(fh)
    claims.pop(sys.argv[1], None)
    with open(path, "w") as fh:
        json.dump(claims, fh, indent=2)
PY
}
