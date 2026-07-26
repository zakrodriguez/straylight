#!/usr/bin/env bash
# Post-deploy hook for hybrid-vpn, invoked by az700.sh with AZ700_RG set.
# Records the VPN gateway's public IP in the env file vpn1's strongSwan
# config reads. Resilient to --no-wait deploys: if the pip is not yet
# allocated, it says what to run later instead of failing the deploy.
set -euo pipefail

ENV_FILE="${HOME}/.straylight/az700/hybrid-vpn.env"
rg="${AZ700_RG:?AZ700_RG not set}"
umask 177

gw_ip="$(az network public-ip show --resource-group "${rg}" --name pip-vpngw \
  --query ipAddress -o tsv 2>/dev/null || true)"
if [[ -z "${gw_ip}" ]]; then
  echo "post-deploy: gateway pip not allocated yet — after 'az700.sh watch hybrid-vpn'," >&2
  echo "post-deploy: re-run 'azure/scripts/az700.sh deploy hybrid-vpn' (idempotent) to record it" >&2
  exit 0
fi

touch "${ENV_FILE}"
grep -v '^GATEWAY_PUBLIC_IP=' "${ENV_FILE}" > "${ENV_FILE}.tmp" || true
mv "${ENV_FILE}.tmp" "${ENV_FILE}"
echo "GATEWAY_PUBLIC_IP=${gw_ip}" >> "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
echo "post-deploy: gateway public IP ${gw_ip} recorded in ${ENV_FILE}"
