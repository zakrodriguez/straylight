# nat-gateway

VNet (10.104.0.0/24, `defaultOutboundAccess: false`) + one B2ts_v2 VM with no
outbound path at all. The `az700-vnet-4` lab creates the NAT gateway + public
IP and attaches them — explicit outbound is the exercise.

Deploy: `azure/scripts/az700.sh deploy nat-gateway` · Teardown: `azure/scripts/az700.sh destroy nat-gateway`
Cost: < $0.30 per session (B2ts_v2 + NAT GW ~$0.045/hr while attached).
