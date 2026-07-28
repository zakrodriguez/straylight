# hybrid-vpn

Hub VNet + VPN gateway (VpnGw1AZ, **20-45 min to provision**, ~$0.36/hr) +
local network gateway describing the Straylight lab (192.168.56.0/21) +
S2S connection + one B2ts_v2 VM. The hybrid module will add vpn1
(strongSwan) to the Vagrant lab as initiator; Azure responds — no home
port-forwards. `params.sh` supplies the on-prem
IP and a persisted PSK at deploy time (`~/.straylight/az700/hybrid-vpn.env`,
0600); nothing secret is committed.

Deploy: `azure/scripts/az700.sh deploy hybrid-vpn --no-wait` then `watch hybrid-vpn` · Teardown: `azure/scripts/az700.sh destroy hybrid-vpn`
Cost: ~$0.36/hr while the gateway exists — never leave it up overnight.

## Tunnel-up runbook (on-prem side = the Straylight lab)

Run from the operator's real uplink (the LNG address is your public IP):

```bash
azure/scripts/az700.sh deploy hybrid-vpn --no-wait   # ~21 min; writes the env file
azure/scripts/az700.sh watch hybrid-vpn              # gate on Succeeded
azure/scripts/az700.sh deploy hybrid-vpn             # idempotent re-run records the gateway pip
cd vagrant && LAB_PROFILE=az700-hybrid ./up.sh       # dc1 + vpn1 (vpn1 reads the env file)
# If vpn1 predates the deploy: LAB_PROFILE=az700-hybrid vagrant provision vpn1
```

Verify: `sudo swanctl --list-sas` on vpn1 shows `ESTABLISHED`; Azure side
`az network vpn-connection show -g rg-straylight-az700-hybrid-vpn -n cn-straylight-s2s --query connectionStatus`
flips to `Connected`. If your public IP changed since the deploy:
`azure/scripts/az700.sh update-onprem-ip hybrid-vpn`, then re-provision vpn1.
