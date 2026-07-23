#!/usr/bin/env bash
# az700.sh — deploy/teardown driver for the AZ-700 track's ephemeral Azure labs.
#
# Every lab lives in its own resource group (rg-straylight-az700-<slug>),
# tagged {project=straylight, track=az700, lab=<slug>, created=<iso8601>}.
# Deploy → run the walkthrough → destroy the same day; `sweep` is the safety
# net for anything left behind. See azure/README.md and azure/docs/teardown.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: az700.sh <command> [args]

  init                       one-time: subscription check, $25/mo budget, claims file
  deploy <slug> [--no-wait]  create the lab's RG and deploy azure/labs/<slug>
  watch <slug>               poll the deployment until Succeeded/Failed
  destroy <slug> [--wait]    delete the lab's RG (async unless --wait)
  list                       show track RGs and local claims
  sweep [--max-age H] [--delete]
                             report (and optionally delete) RGs older than H hours (default 8)
  nuke [--yes]               delete ALL track RGs
  update-onprem-ip <slug>    refresh the local network gateway with the current public IP
  cost                       best-effort month-to-date spend for the track

Environment: AZURE_SUBSCRIPTION_ID (pin, via vagrant/.env), AZ700_LOCATION
(default centralus), AZ700_YES=1 (skip confirmations).
EOF
  exit 1
}

preflight() {
  az700::require_az
  az700::require_login
  az700::load_env
  az700::require_subscription
}

# Refuse to stack labs silently: surface any OTHER track RG before deploying.
stale_check() {
  local target="$1" stale
  stale="$(az700::list_rgs | awk -v t="${target}" '$1 != t {print $1}')"
  if [[ -n "${stale}" ]]; then
    az700::warn "existing AZ-700 resource groups (still costing money):"
    echo "${stale}" | sed 's/^/  - /' >&2
    az700::confirm "Deploy anyway?"
  fi
}

cmd_init() {
  preflight
  mkdir -p "${HOME}/.straylight"
  [[ -f "${CLAIMS_FILE}" ]] || echo '{}' > "${CLAIMS_FILE}"
  local start
  start="$(date -u +%Y-%m-01)"
  if az consumption budget create --budget-name straylight-az700 --amount 25 \
    --category cost --time-grain monthly --start-date "${start}" \
    --end-date "$(date -u -d '+2 years' +%Y-%m-01)" >/dev/null 2>&1; then
    echo "budget 'straylight-az700' created: \$25/month"
  else
    az700::warn "could not create the budget via CLI (offer type may not support it)."
    az700::warn "Create it in the portal instead: Cost Management > Budgets > Add,"
    az700::warn "amount 25 USD/month, alerts at 50/80/100% to your email."
  fi
  echo "init complete. Next: az700.sh deploy hub-spoke"
}

cmd_deploy() {
  local slug="${1:-}" no_wait=0
  [[ -n "${slug}" ]] || usage
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-wait) no_wait=1 ;;
      --wait) no_wait=0 ;;
      *) usage ;;
    esac
    shift
  done
  local lab_dir="${AZURE_DIR}/labs/${slug}"
  [[ -f "${lab_dir}/main.bicep" ]] || az700::die "no such lab topology: ${lab_dir}/main.bicep"
  preflight
  stale_check "$(az700::rg_name "${slug}")"

  local rg loc
  rg="$(az700::rg_name "${slug}")"
  loc="$(az700::location)"
  echo "creating ${rg} in ${loc}"
  az group create --name "${rg}" --location "${loc}" \
    --tags project=straylight track=az700 "lab=${slug}" "created=$(date -u +%FT%TZ)" \
    --output none
  az700::claim_add "${slug}" "${rg}"

  local -a extra=()
  [[ -f "${lab_dir}/main.bicepparam" ]] && extra+=(--parameters "${lab_dir}/main.bicepparam")
  if [[ "${no_wait}" == "1" ]]; then
    az deployment group create --resource-group "${rg}" --name main \
      --template-file "${lab_dir}/main.bicep" "${extra[@]+"${extra[@]}"}" \
      --no-wait --output none
    echo "deployment submitted (async). Gate on it with: az700.sh watch ${slug}"
  else
    az deployment group create --resource-group "${rg}" --name main \
      --template-file "${lab_dir}/main.bicep" "${extra[@]+"${extra[@]}"}" \
      --query properties.provisioningState -o tsv
  fi
  if [[ -x "${lab_dir}/post-deploy.sh" ]]; then
    AZ700_RG="${rg}" "${lab_dir}/post-deploy.sh"
  fi
}

cmd_watch() {
  local slug="${1:-}"
  [[ -n "${slug}" ]] || usage
  preflight
  local rg state
  rg="$(az700::rg_name "${slug}")"
  for _ in $(seq 1 120); do
    state="$(az deployment group show --resource-group "${rg}" --name main \
      --query properties.provisioningState -o tsv 2>/dev/null || echo Pending)"
    echo "$(date -u +%H:%M:%S) ${slug}: ${state}"
    case "${state}" in
      Succeeded) return 0 ;;
      Failed|Canceled) az700::die "deployment ${state}" ;;
    esac
    sleep 30
  done
  az700::die "timed out after 60 minutes"
}

cmd_destroy() {
  local slug="${1:-}" wait_flag=0
  [[ -n "${slug}" ]] || usage
  [[ "${2:-}" == "--wait" ]] && wait_flag=1
  preflight
  local rg
  rg="$(az700::rg_name "${slug}")"
  az700::assert_az700_rg "${rg}"
  if [[ "${wait_flag}" == "1" ]]; then
    az group delete --name "${rg}" --yes
  else
    az group delete --name "${rg}" --yes --no-wait
    echo "delete submitted for ${rg} (async); confirm later with: az700.sh list"
  fi
  az700::claim_remove "${slug}"
}

cmd_list() {
  preflight
  echo "AZ-700 resource groups (name prefix + track tag):"
  az700::list_rgs | awk '{printf "  %-40s created=%s\n", $1, $2}'
  if [[ -f "${CLAIMS_FILE}" ]]; then
    echo "local claims (${CLAIMS_FILE}):"
    python3 -m json.tool "${CLAIMS_FILE}"
  fi
}

cmd_sweep() {
  local max_age=8 do_delete=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-age) max_age="$2"; shift ;;
      --delete) do_delete=1 ;;
      *) usage ;;
    esac
    shift
  done
  preflight
  local stale
  stale="$(az700::list_rgs | python3 -c '
import sys, time
max_age_h = float(sys.argv[1])
now = time.time()
for line in sys.stdin:
    parts = line.strip().split("\t")
    if not parts or not parts[0]:
        continue
    name = parts[0]
    created = parts[1] if len(parts) > 1 else ""
    try:
        age_h = (now - time.mktime(time.strptime(created, "%Y-%m-%dT%H:%M:%SZ"))) / 3600
    except ValueError:
        age_h = max_age_h + 1  # unparseable/missing created tag counts as stale
    if age_h > max_age_h:
        print(f"{name}\t{age_h:.1f}")
' "${max_age}")"
  if [[ -z "${stale}" ]]; then
    echo "sweep: no AZ-700 resource groups older than ${max_age}h"
    return 0
  fi
  az700::warn "STALE resource groups (> ${max_age}h old, still costing money):"
  echo "${stale}" | awk '{printf "  - %s (%.0fh)\n", $1, $2}' >&2
  if [[ "${do_delete}" == "1" ]]; then
    while IFS=$'\t' read -r name _; do
      az700::assert_az700_rg "${name}"
      az group delete --name "${name}" --yes --no-wait
      echo "delete submitted: ${name}"
    done <<< "${stale}"
  else
    az700::warn "re-run with --delete to remove them"
    return 1
  fi
}

cmd_nuke() {
  [[ "${1:-}" == "--yes" ]] && export AZ700_YES=1
  preflight
  local rgs
  rgs="$(az700::list_rgs | cut -f1)"
  if [[ -z "${rgs}" ]]; then
    echo "nuke: no AZ-700 resource groups exist"
    return 0
  fi
  echo "${rgs}" | sed 's/^/  - /'
  az700::confirm "Delete ALL of the above?"
  while read -r name; do
    az700::assert_az700_rg "${name}"
    az group delete --name "${name}" --yes --no-wait
    echo "delete submitted: ${name}"
  done <<< "${rgs}"
  echo "all deletes submitted; confirm later with: az700.sh list"
}

cmd_update_onprem_ip() {
  local slug="${1:-}"
  [[ -n "${slug}" ]] || usage
  preflight
  local rg ip lgw
  rg="$(az700::rg_name "${slug}")"
  ip="$(curl -fsS https://api.ipify.org)"
  [[ -n "${ip}" ]] || az700::die "could not determine the public IP"
  lgw="$(az network local-gateway list --resource-group "${rg}" --query '[0].name' -o tsv)"
  [[ -n "${lgw}" ]] || az700::die "no local network gateway in ${rg}"
  az network local-gateway update --resource-group "${rg}" --name "${lgw}" \
    --gateway-ip-address "${ip}" --output none
  echo "${lgw}: gateway address updated to ${ip}"
}

cmd_cost() {
  preflight
  local start
  start="$(date -u +%Y-%m-01)"
  if ! az consumption usage list --start-date "${start}" --end-date "$(date -u +%F)" \
    --query "[?contains(instanceName, 'straylight-az700')].{name:instanceName, cost:pretaxCost}" \
    -o table 2>/dev/null; then
    az700::warn "consumption API not available on this offer type — check Cost Management in the portal"
  fi
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  list) shift; cmd_list "$@" ;;
  sweep) shift; cmd_sweep "$@" ;;
  nuke) shift; cmd_nuke "$@" ;;
  update-onprem-ip) shift; cmd_update_onprem_ip "$@" ;;
  cost) shift; cmd_cost "$@" ;;
  *) usage ;;
esac
