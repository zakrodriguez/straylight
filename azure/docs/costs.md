# AZ-700 track — per-session costs

Estimates for a 3–4 hour deploy→run→destroy session at pay-as-you-go US rates,
checked 2026-07. Prices drift: each module's design spec re-verifies them at
writing time, and walkthroughs claim bands ("under a dollar"), never exact
figures. The worst realistic month (a dozen sessions plus one forgotten
overnight gateway caught by the 23:00 sweep) stays under the $25 budget.

| Topology | Metered pieces | Est./session |
|---|---|---|
| hub-spoke | 1 × B2ts_v2 (~$0.01/hr); VNets/peerings ~free at lab volume | < $0.25 |
| nat-gateway | NAT GW ~$0.045/hr + data + PIP + 1 × B2ts_v2 | < $0.30 |
| hybrid-vpn (flagship) | VpnGw1AZ ~$0.19/hr (≈4 h incl. 30–45 min provision), Standard PIP, 2 × B2ts_v2, private endpoint ~$0.01/hr, private DNS zone prorated | ~$1.00–1.50 |
| p2s-vpn | same gateway economics, no LNG | ~$0.90 |
| lb-standard / private-link | Std LB ~$0.025/hr, PE ~$0.01/hr, 2 × B2ts_v2 | < $0.50 |
| appgw | AppGW Standard_v2 ~$0.25/hr + CU, backend B2ts_v2 | ~$1.00 |
| dns-private-resolver | inbound endpoint ~$0.25/hr + ruleset prorated, on top of the hybrid stack | ~$2.50 combined |
| firewall-basic | Azure Firewall Basic ~$0.40/hr | ~$1.50 |
| route-server | ~$0.45/hr (verify at spec time) + NVA B2ts_v2 | ~$1.50 |
| vwan-lite (optional) | hub ~$0.25/hr + S2S scale unit ~$0.36/hr | ~$2.50–3.00 |
| expressroute / firewall-premium / ddos | — | paper labs, $0 |

## Cost discipline

- Deploy right before the lab, destroy right after — the walkthroughs make
  both explicit, annotated steps.
- Gateway sessions amortize: the hybrid module's S2S/BGP labs are written to
  run back-to-back against one gateway deploy.
- `az700.sh sweep` reports anything older than 8 h; the optional nightly timer
  deletes it.

## CGNAT precheck (free, do once before the hybrid module)

The S2S tunnel assumes your ISP gives the router a real (if dynamic) public
IP. Compare the router's WAN address with `curl https://api.ipify.org` — if
they differ (or the WAN address is in 100.64.0.0/10), you are behind CGNAT and
IKE NAT-T may not survive; the hybrid module's P2S plan-B applies. Record the
result here when you run it:

- [x] CGNAT precheck run: date 2026-07-25, WAN IP matches public IP: **yes**
  (evidence: hop 2 after the router is a public Charter backbone address —
  `tracepath` shows no 100.64.0.0/10 or private carrier hop — and the
  ipify-reported address sits in ordinary Charter residential space; no CGNAT
  layer exists. S2S is GO.)

## hybrid-vpn (the expensive topology)

The VPN gateway (VpnGw1AZ) runs ~$0.36/hr **from creation, including the
20-45 min provisioning window**. A full lab session (deploy, two labs,
teardown) lands around $1-1.50. Never leave it up overnight — that's ~$9/day;
the sweep timer is the backstop, same-day `destroy hybrid-vpn` is the rule.
