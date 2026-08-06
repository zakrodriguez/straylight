# ExpressRoute — paper reference architecture

Doc-only. There is **no `main.bicep` here and nothing to deploy** — an
ExpressRoute circuit needs a connectivity-provider relationship and bills in
the hundreds per month, so the track treats it as a paper lab. The teaching
walkthrough is
`docs/walkthroughs/az700-labs/az700-hybrid-6-expressroute-paper-walkthrough.md`;
this file is the reference architecture it points at.

## Reference topology

```
 On-prem edge ─┬─ primary link ──┐
               │                 ├─ Connectivity provider ── MSEE routers ─┬─ Azure private peering ── ExpressRoute GW ── VNet
               └─ secondary link ┘   (or ExpressRoute Direct: your own      └─ Microsoft peering ────── Microsoft public services
                                      10/100G ports, no provider)
```

- **Circuit** — the logical Azure resource; created by you, lit by the
  provider via the **service key**. Redundant by design (primary + secondary).
- **Peerings** — separate BGP routing domains on the circuit:
  **private** (reaches VNets; needs an **ExpressRoute-type** gateway in a
  `GatewaySubnet`) and **Microsoft** (reaches Microsoft public services).
  Public peering is **retired**.
- **SKU** — Local (metro, no egress charge) / Standard (geopolitical area) /
  **Premium** (global reach, higher route + VNet limits).
- **Billing** — Metered (port + per-GB egress) or Unlimited (flat).

## Design rules the exam tests

| Requirement | Answer |
|---|---|
| Reach VNets privately over the circuit | Azure **private peering** + an **ExpressRoute** gateway (not a VPN gateway) |
| Branch-to-branch over the Microsoft backbone | **Global Reach** (links two circuits) |
| No provider; sovereign / MACsec | **ExpressRoute Direct** (your own 10/100G ports) |
| Lowest gateway latency to the VM | **FastPath** (data path bypasses the gateway routing hop) |
| Private **and** encrypted | IPsec over private peering, or MACsec on ER Direct — ER is **not** encrypted by default |
| 99.95% SLA | **two circuits** / redundant peering locations — never a single circuit |
| ExpressRoute + S2S VPN together | **coexistence**: ER primary, VPN encrypted backup, arbitrated by **BGP** |

## Not deployed here

No circuit, no ExpressRoute gateway, no ER Direct port, no Global Reach — all
paper. The only ExpressRoute-adjacent thing the track deploys is the BGP that
makes coexistence work, and that lives in the `hybrid-vpn` topology (Lab 3).
