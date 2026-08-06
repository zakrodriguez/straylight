# AZ-700 P3b — Hybrid Labs 4–6 + DNS Private Resolver — Design

**Date:** 2026-07-30
**Companion to:** MS Learn AZ-700 learning path, *Design and implement hybrid
network connectivity* (point-to-site VPN, Virtual WAN, ExpressRoute) and
*Design and implement name resolution* (DNS Private Resolver)
**Predecessor pattern:** `2026-07-28-az700-hybrid-labs-design.md` (hybrid labs
1–3; shipped v2.13.0) and `2026-07-25-az700-dns-labs-design.md` (dns labs 1–2)

## Goal

Close the two modules the prior phases left open-ended. The hybrid module
graduated with labs 1–3 (VPN gateway anatomy, the S2S tunnel, BGP); P3b adds
its remaining three: **point-to-site VPN**, **Virtual WAN**, and
**ExpressRoute** (a paper lab). The dns module shipped labs 1–2 and always
carried a deferred third — **DNS Private Resolver** — parked until the hybrid
tunnel existed. Both land here, plus their quizzes and a light hands-on pass
over the two existing module exams (which already examine these topics as
concepts; P3b makes them hands-on).

Net new: 4 labs (3 hybrid + 1 dns) + 4 quizzes + this spec + one new Bicep
topology (`dns-private-resolver`) + one runbook topology (`vwan-lite`) + one
paper doc (`azure/labs/paper/expressroute.md`). The two module exams gain a
handful of questions each; no new exam file.

## MS Learn → lab mapping

| MS Learn topic | Lab | Tier |
|---|---|---|
| Point-to-site VPN: client address pool, tunnel types, auth models | `az700-hybrid-4-point-to-site-walkthrough.md` | VERIFIABLE (config) |
| Virtual WAN: virtual hubs, any-to-any, secured hub / routing intent | `az700-hybrid-5-virtual-wan-walkthrough.md` | RUNBOOK (no golden) |
| ExpressRoute: circuits, peering, SKUs, Global Reach, coexistence | `az700-hybrid-6-expressroute-paper-walkthrough.md` | PAPER (no resources) |
| DNS Private Resolver: inbound/outbound endpoints, forwarding rulesets | `az700-dns-3-private-resolver-walkthrough.md` | VERIFIABLE (config) |

## Deploy contract (locked)

Four labs, three deploy shapes — chosen for the frugality rule the track runs
on. Every metered piece is inspected, then torn down the same day.

### Lab 4 — Point-to-site: reuse the hybrid-vpn gateway, no new topology

P2S is a **configuration on an existing route-based gateway**, not a new
resource. The exam skill is configuring the P2S profile — the client address
pool, the tunnel protocol, and the authentication model — all of which are
inspectable via `az network vnet-gateway show --query vpnClientConfiguration`.
So Lab 4 stands up nothing new: it reuses the **already-deployed
`hybrid-vpn`** gateway (labs 1–3), enables the P2S profile as a lab step
(`az network vnet-gateway update`), and asserts the resulting configuration.

- **Address pool** `172.16.201.0/24` — the `p2sPool` already reserved in
  `azure/modules/naming.bicep`, deliberately outside `10.100.0.0/14` and the
  on-prem `192.168.56.0/21` so client addresses never collide with either.
- **Tunnel type** OpenVPN + IKEv2 (both enabled; OpenVPN is the one that also
  unlocks Microsoft Entra ID auth).
- **Auth model** Azure certificate (a self-signed root, taught inline). The
  lab teaches the Entra-ID and RADIUS models as prose — actually connecting a
  client is a Windows/OpenVPN-client task outside the Linux host's reach, so
  the **client connect itself is a runbook note, not an asserted step**.

The P2S config is added and then removed inside the same session (a lab step
clears `vpnClientConfiguration` before teardown) so labs 1–3 goldens, which
assert the gateway with no P2S profile, are unaffected on a later recapture.

### Lab 5 — Virtual WAN: `vwan-lite` topology, runbook only

Virtual WAN is a different resource model (a `virtualWan`, one or more
`virtualHubs`, and hub connections) with its own routing-infrastructure cost
and a ~30-minute hub provision. It is **latency-flaky and pricier than the
rest of the track**, so — exactly as the plan scoped it — Lab 5 is
**runbook-style with no golden**. The `azure/labs/vwan-lite/` topology
(a Standard `virtualWan` + one `virtualHub` + one VNet connection) exists so
the runbook is reproducible for anyone who wants to pay for a session, but it
is never part of the verified set and never CI-touched beyond `bicep build`.
The lab's teaching value is the **model contrast** — vWAN's Microsoft-managed
any-to-any hub versus the self-managed hub-and-spoke of the vnet module — and
secured-hub / routing-intent concepts.

### Lab 6 — ExpressRoute: paper lab, zero resources

ExpressRoute circuits cannot be provisioned frugally (a real circuit needs a
connectivity provider and is billed in hundreds/month) and have no local
verification surface. Lab 6 is a **paper lab**: a walkthrough that reads like
the others but carries no `@verify` sentinels and creates nothing. The
doc-only `azure/labs/paper/expressroute.md` holds the reference architecture;
the walkthrough teaches circuits, the peering types (private + Microsoft;
public peering is retired), SKUs (Local/Standard/Premium), billing
(Metered/Unlimited), Global Reach, ExpressRoute Direct, FastPath, and
**VPN + ExpressRoute coexistence** (which is why BGP in Lab 3 mattered).

### dns-3 — DNS Private Resolver: new standalone `dns-private-resolver` topology

A resolver is a **deployed resource**, not a lab step (unlike the dns module's
zones), so it gets its own topology. It is **standalone** — its own small
VNet, not folded into `hub-spoke` or `hybrid-vpn` — because the resolver
mechanics (inbound endpoint, outbound endpoint, forwarding ruleset, VNet
links) are fully demonstrable and verifiable in isolation, cheaply, with no
gateway. The **hybrid resolution story** (on-prem `dc1` conditional-forwards
to the inbound endpoint over the tunnel; Azure forwards `*.straylight.lab`
back out via the outbound endpoint's ruleset) needs `hybrid-vpn` standing and
is taught as a **runbook extension** at the end of the lab, not an asserted
step — it is the one part that would require the expensive gateway.

`azure/labs/dns-private-resolver/` deploys:

| Piece | Detail |
|---|---|
| VNet `vnet-dnsr` | `10.103.4.0/24` (inside `10.100.0.0/14`, clear of hub/spokes/nat-gateway) |
| `snet-inbound` `10.103.4.0/28` | delegated to `Microsoft.Network/dnsResolvers` |
| `snet-outbound` `10.103.4.16/28` | delegated to `Microsoft.Network/dnsResolvers` (endpoints need **separate** subnets) |
| `snet-workload` `10.103.4.32/27` | `vm-dnsr1` (B2ts_v2) for resolution probes |
| `dnsr-straylight` | the resolver, linked to `vnet-dnsr` |
| inbound endpoint | private-IP listener in `snet-inbound` (what on-prem forwards to) |
| outbound endpoint | egress point in `snet-outbound` |
| `fwrs-straylight` ruleset | one forwarding rule (`straylight.lab.` → a target IP), VNet-linked to `vnet-dnsr` |

The address plan in `naming.bicep` gains a `dnsResolver` block for these
prefixes (single source of truth, same as every other subnet). The lab
requires the `dns-resolver` az CLI extension (installed in Setup).

## Cost table (locked)

| Lab | Metered pieces | Session estimate |
|---|---|---|
| 4 (P2S) | reuses the standing `hybrid-vpn` gateway (already counted in labs 1–3); P2S adds no metered resource | ~$0 incremental (fold into the labs 1–4 gateway sitting) |
| 5 (vWAN) | Standard virtual hub routing infra ~$0.25/hr + connection ~$0.02/hr + data GB | **~$0.60 for a short runbook sitting**; the module's second-most-expensive after the gateway |
| 6 (ER) | none — paper | $0 |
| dns-3 | 2 resolver endpoints ~$0.07/hr each + 1 × B2ts_v2 + queries (per-million, negligible) | **< $0.30** for a deploy-inspect-destroy sitting |

The hybrid module's iron rule still holds: the `hybrid-vpn` gateway (labs 1–4)
never survives a session. vWAN's hub is the new thing to remember to destroy —
`destroy vwan-lite` the same day.

## Verification model

Same as the hybrid and dns modules, with the tier per lab fixed above:

- **Lab 4 (P2S)** and **dns-3** are VERIFIABLE at the **config** level:
  assertions target the P2S profile / resolver config projected with
  `--query <JMESPath> -o tsv`, never the live client tunnel or a cross-tunnel
  DNS answer (those need Windows-side or gateway-standing state). Goldens are
  **skeletons now**; capture is a **deferred paid session** — Lab 4 captures
  alongside a labs 1–4 gateway sitting; dns-3 captures in its own short
  resolver sitting. This is the same authored-first, capture-later pattern the
  hybrid module used for labs 1–3 (#273 → #274/#275).
- **Lab 5 (vWAN)** is RUNBOOK — no golden, no `@verify`; commands are shown
  with expected shapes in prose, latency/cost make replay a judgment call.
- **Lab 6 (ER)** is PAPER — no golden, no commands that touch Azure.
- Azure `verify`/`check` replays stay **manual-only, never CI** (every replay
  costs real dollars); capture/check use `--vagrant-root <repo root>`
  (host=lab cwd rule). Public IPs and resolver private IPs are never asserted
  as literals — assertions target states and shapes.
- az prints tsv booleans **lowercase**; expects are written lowercase (the
  standing gotcha from every prior module).

## Non-goals

- No live P2S client connection asserted (Windows/OpenVPN-client task); no
  Entra-ID or RADIUS P2S deployment (taught as prose).
- No secured virtual hub with Azure Firewall / routing intent deployed (cost);
  vWAN security is concept + runbook only.
- No real ExpressRoute circuit, ER Direct port, or Global Reach — paper only.
- No cross-tunnel DNS answer asserted in dns-3 (needs `hybrid-vpn` standing);
  the hybrid-resolution wiring is a runbook extension.
- No DNSSEC, no private resolver in the hub VNet (kept standalone for cost and
  blast-radius).
