# dns-private-resolver

Standalone DNS Private Resolver: VNet `vnet-dnsr` (10.103.4.0/24) with
inbound/outbound endpoints on their own /28 subnets delegated to
`Microsoft.Network/dnsResolvers`, a forwarding ruleset (`straylight.lab.` →
on-prem), and a B2ts_v2 probe VM. Serves the `az700-dns-3` walkthrough. The
cross-tunnel hybrid-resolution story needs `hybrid-vpn` standing and is a
runbook extension in the lab, not deployed here.

Deploy: `azure/scripts/az700.sh deploy dns-private-resolver` · Teardown: `azure/scripts/az700.sh destroy dns-private-resolver`
Cost: < $0.30 per session (2 resolver endpoints ~$0.07/hr each + 1 × B2ts_v2; queries per-million, negligible).
