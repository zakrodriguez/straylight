#!/usr/bin/env bash
# Dynamic parameters for the hybrid-vpn topology, invoked by az700.sh deploy.
# stdout is consumed as `key=value` deployment parameters — everything else
# goes to stderr. The PSK is generated once and persisted (0600) so repeat
# deploys keep the key vpn1 already knows; delete the env file to rotate.
set -euo pipefail

ENV_DIR="${HOME}/.straylight/az700"
ENV_FILE="${ENV_DIR}/hybrid-vpn.env"

onprem_ip="$(curl -fsS --max-time 15 https://api.ipify.org)"
[[ -n "${onprem_ip}" ]] || { echo "params.sh: could not determine the public IP" >&2; exit 1; }

shared_key=""
if [[ -f "${ENV_FILE}" ]]; then
  shared_key="$(sed -n 's/^SHARED_KEY=//p' "${ENV_FILE}")"
fi
if [[ -z "${shared_key}" ]]; then
  shared_key="$(openssl rand -base64 24)"
  echo "params.sh: generated a new shared key (persisted to ${ENV_FILE})" >&2
fi

mkdir -p "${ENV_DIR}"
umask 177
cat > "${ENV_FILE}" <<EOF
ONPREM_IP=${onprem_ip}
SHARED_KEY=${shared_key}
EOF
echo "params.sh: on-prem IP ${onprem_ip}; env written to ${ENV_FILE}" >&2

echo "onpremIp=${onprem_ip} sharedKey=${shared_key}"
