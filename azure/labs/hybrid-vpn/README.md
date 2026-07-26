# hybrid-vpn

Hub VNet + VPN gateway (VpnGw1AZ, **20-45 min to provision**, ~$0.36/hr) +
local network gateway describing the Straylight lab (192.168.56.0/21) +
S2S connection + one B2ts_v2 VM. The lab's vpn1 (strongSwan) initiates;
Azure responds — no home port-forwards. `params.sh` supplies the on-prem
IP and a persisted PSK at deploy time (`~/.straylight/az700/hybrid-vpn.env`,
0600); nothing secret is committed.

Deploy: `azure/scripts/az700.sh deploy hybrid-vpn --no-wait` then `watch hybrid-vpn` · Teardown: `azure/scripts/az700.sh destroy hybrid-vpn`
Cost: ~$0.36/hr while the gateway exists — never leave it up overnight.
