# AZ-700 Hybrid Connectivity Labs — Design

**Date:** 2026-07-28
**Companion to:** MS Learn AZ-700 learning path, *Design and implement
hybrid network connectivity* (site-to-site VPN, VPN gateways, BGP over VPN)
**Predecessor pattern:** `2026-07-25-az700-dns-labs-design.md` (dns module;
shipped v2.11.0) and `2026-07-18-az700-vnet-labs-design.md` (vnet module)

## Goal

Fourth module of the AZ-700 track and the track's flagship: connect the
Straylight lab to Azure as a real on-premises site over a site-to-site
IKEv2 VPN. Three hands-on labs now — VPN gateway anatomy, the S2S tunnel
end to end, and BGP over the tunnel — plus quizzes and the module exam.
Labs 4–6 (point-to-site, Virtual WAN, and ExpressRoute as a paper lab)
land later with P3b, as does the deferred `az700-dns-3` DNS Private
Resolver lab, which needs this tunnel standing.

Unlike the vnet and dns modules, the hybrid labs are **not** azure-only.
They span three hosts: `host=lab` (az CLI, the Azure control plane),
`host=vpn1` (the strongSwan initiator — swanctl, ping), and `host=dc1`
(a Windows on-prem host routing to Azure). The lab *is* the on-prem site.

## Prerequisite: the CGNAT precheck

The S2S tunnel needs the operator's router to hold a real (if dynamic)
public IP. Before the first session, run the free precheck in
`azure/docs/costs.md` — compare the router's WAN address with
`curl https://api.ipify.org`. If they differ (or the WAN address is in
`100.64.0.0/10`), you are behind carrier-grade NAT and IKE NAT-T may not
survive; the P2S plan-B labs (P3b) apply instead. This was run
2026-07-25 for the reference lab: **no CGNAT, S2S is GO.**

## MS Learn → lab mapping

| MS Learn topic (Design and implement hybrid connectivity) | Lab |
|---|---|
| VPN gateway types, SKUs, generations, the connection model | `az700-hybrid-1-vpn-gateway-anatomy-walkthrough.md` |
| Site-to-site IKEv2: negotiation, traffic selectors, reachability | `az700-hybrid-2-site-to-site-tunnel-walkthrough.md` |
| BGP over VPN: dynamic routes, ASNs, APIPA peers | `az700-hybrid-3-bgp-over-vpn-walkthrough.md` |
| Point-to-site, Virtual WAN, ExpressRoute (paper) | deferred — P3b |

Net new: 3 labs + 3 quizzes + this spec + the module exam.

## Deploy contract (locked)

Two deployments, both stood up before the labs and torn down after:

| Piece | Command | What it provides | Time / cost |
|---|---|---|---|
| Azure side | `azure/scripts/az700.sh deploy hybrid-vpn --no-wait` | hub VNet + `vpngw-hub` (VpnGw1AZ) + `pip-vpngw` + `lgw-straylight` (the lab as on-prem) + `cn-straylight-s2s` connection + `vm-hub1` test VM | **20–45 min** gateway provision, **~$0.36/hr** while up |
| On-prem side | `LAB_PROFILE=az700-hybrid ./up.sh` | `dc1` (corporate DC) + `vpn1` (strongSwan initiator, octet 45) | ~25 min (dc1 promo); free |

`params.sh` writes the on-prem public IP and a persisted PSK to
`~/.straylight/az700/hybrid-vpn.env` at deploy time; `post-deploy.sh`
records the gateway's public IP there once allocated. `vpn1`'s
`strongswan_azure` role reads that env file and renders the tunnel — so
**vpn1 must be (re-)provisioned after the gateway's public IP is
recorded**. The runbook is in `azure/labs/hybrid-vpn/README.md`.

### The pinned IPsec policy (learned live 2026-07-27)

The connection carries an **explicit** IPsec/IKE policy
(AES256/SHA256/DHGroup14 IKE, AES256/SHA256/no-PFS IPsec) rather than
Azure's default policy set. The first live tunnel-up proved Azure's
default policy would not negotiate with strongSwan on VpnGw1AZ — the
initiator got `NO_PROPOSAL_CHOSEN` at IKE_SA_INIT for every combination
in Azure's *documented* default list. Pinning one policy on both sides
makes negotiation deterministic. Lab 2 teaches this directly.

## Cost table (locked; the track's one expensive module)

| Lab | Metered pieces | Session estimate |
|---|---|---|
| 1 | VpnGw1AZ ~$0.36/hr + 1 Standard pip; gateway provision counts | < $0.50 (deploy + inspect, then continue to Lab 2) |
| 2 | same gateway (already up) + 1 × B2ts_v2 (vm-hub1) | included in the session |
| 3 | same gateway; BGP adds no metered resource | included in the session |
| Whole module, one sitting | gateway ~$0.36/hr × ~1.5 h | **~$0.55, gateway-dominated** |

The gateway dominates cost and never survives a session. The rule is
firmer here than anywhere else in the track: **`destroy hybrid-vpn` the
same day** — a forgotten gateway is ~$9/day.

## Verification model

Same as the other modules, with hybrid-specific notes:

- Asserted steps project with `--query <JMESPath> -o tsv` (host=lab) or
  parse `swanctl`/`ping`/`Get-NetRoute` output (host=vpn1 / host=dc1).
- **Golden capture requires a standing tunnel** — a deployed gateway
  (real money) plus the on-prem side up and the SA established. Unlike the
  azure-only modules, these goldens cannot be captured cheaply; capture is
  a deliberate live session, cadence pre-graduation only.
- Azure `connectionStatus` and byte counters lag the data plane by
  minutes — the `swanctl` SA state and an actual ping are the authoritative
  "is it up" signals; the Azure status field is a lagging confirmation.
- IPs are never asserted as literals (the lab allocates a dynamic /24, and
  the gateway/on-prem public IPs are volatile) — assertions target states
  (`ESTABLISHED`, `Connected`, `Succeeded`) and reachability, not addresses.

## Lab 3 (BGP) infrastructure dependency

Lab 3 requires BGP enabled on the connection and a BGP speaker on `vpn1`.
The shipped `lng-connection.bicep` sets `enableBgp: false` and the LNG
carries only a static `localNetworkAddressSpace`; the `strongswan_azure`
role installs no BGP daemon. Lab 3's **Part A** documents that increment
(LNG `bgpSettings` with the on-prem ASN + BGP peer IP, connection
`enableBgp: true`, and FRR on vpn1 peering the Azure gateway's APIPA BGP
address). Until that increment ships, Lab 3 is authored content with a
skeleton golden; its golden captures alongside Labs 1–2 once the BGP
infra lands. This is called out in the lab's header, not buried.

## Non-goals

- No ExpressRoute, no Virtual WAN, no active-active or zone-redundant
  multi-gateway topologies (cost) — paper labs / P3b.
- No production PSK handling guidance beyond the persisted-env pattern;
  the lab PSK is generated and lab-scoped.
- No custom on-prem firewall/NAT traversal beyond the initiator-behind-NAT
  case the VBox+home-router topology already exercises.
