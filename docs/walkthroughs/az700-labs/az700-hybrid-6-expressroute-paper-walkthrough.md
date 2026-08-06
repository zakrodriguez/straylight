# AZ-700 Hybrid Lab 6 — ExpressRoute (Paper Lab)

ExpressRoute is the third way into Azure — not over the public internet at
all, but over a **private connection** through a connectivity provider. It is
the exam's premium hybrid path: higher throughput, a real SLA, predictable
latency, and no IPsec. You will not deploy one — a circuit needs a provider
relationship and bills in the hundreds per month — so this is a **paper lab**.
It reads like the others, but nothing here touches Azure and there is no cost.
The goal is to know the model well enough to answer design questions and to
place ExpressRoute correctly against the VPN gateways from Labs 1–5.

Pairs with MS Learn: *Design and implement hybrid connectivity* — connect
networks with ExpressRoute (AZ-700 learning path).

> **Paper lab**: no deployment, no `az700.sh`, no cost. The reference
> architecture lives in `azure/labs/paper/expressroute.md`. Read this, then
> use the quiz to check yourself.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Labs 1–3 concepts (gateway, connection, BGP) | ExpressRoute reuses the gateway/connection/BGP mental model |
| Verification: PAPER (no golden, no `@verify`) | nothing here is executable against Azure |

## Step 1 — The circuit is not in your subscription

An **ExpressRoute circuit** is a logical resource in Azure that represents a
dedicated Layer-2/Layer-3 connection between your on-prem edge and Microsoft,
established **through a connectivity provider** (an ISP or exchange partner).
The physical path runs provider → Microsoft Enterprise Edge (MSEE) routers;
your circuit is the pair of connections (for redundancy) landing on those
MSEEs. Two identifiers matter:

- The **service key (s-key)** — a GUID Azure generates for the circuit; you
  hand it to the provider to link their side to yours.
- The **circuit state** — a `ServiceProviderProvisioningState`
  (`NotProvisioned` → `Provisioning` → `Provisioned`) the *provider* drives,
  separate from Azure's own `provisioningState`. A circuit you have created
  but the provider has not lit sits `Provisioned: false` — the ExpressRoute
  analogue of Lab 1's `NotConnected` gateway.

Unlike a VPN, **there is no IPsec and no tunnel** — traffic is private by
path, not by encryption. If you need encryption over ExpressRoute you add it
yourself (MACsec on ExpressRoute Direct, or IPsec over private peering).

## Step 2 — Peering: private vs Microsoft

A circuit carries **routing domains** called peerings, each a separate BGP
session over the circuit:

- **Azure private peering** — reaches your VNets (IaaS/PaaS deployed into a
  VNet) on their private IPs. This is the one that replaces or complements the
  VPN gateway's private reach. It needs a `GatewaySubnet` and an
  **ExpressRoute gateway** (gateway type `ExpressRoute`, distinct from the VPN
  gateway type) in the VNet.
- **Microsoft peering** — reaches Microsoft public services (Microsoft 365 in
  limited cases, and Azure PaaS public endpoints) over the circuit instead of
  the internet, advertised to your public prefixes/ASN.
- **Public peering** is **retired** — do not choose it in a design answer; it
  was folded into Microsoft peering.

Each peering runs BGP; you supply a peer ASN and a /30 (or /29) for the two
BGP addresses on each of the primary and secondary links.

## Step 3 — SKUs and billing

Two independent choices:

- **Circuit SKU** — **Local**, **Standard**, or **Premium**. Local is
  cheapest and reaches only Azure regions in the circuit's metro (no data
  transfer charge). Standard reaches any region in the same geopolitical area.
  **Premium** extends reach **globally** (any region worldwide), raises route
  limits (private-peering route count 4k → 10k), and increases the number of
  VNets a circuit can link.
- **Billing model** — **Metered** (flat port fee + per-GB egress) or
  **Unlimited** (higher flat fee, no per-GB). High, steady egress favors
  Unlimited; bursty/low egress favors Metered.

Bandwidth (50 Mbps … 100 Gbps) is a third, separate dial; you can bump it up
on an existing circuit without re-provisioning.

## Step 4 — Global Reach, ExpressRoute Direct, FastPath

Three add-ons the exam likes:

- **Global Reach** — links two ExpressRoute circuits so your **on-prem sites
  talk to each other through the Microsoft backbone** (branch-to-branch),
  bypassing your WAN. It is a circuit-to-circuit feature, not a VNet feature.
- **ExpressRoute Direct** — you provision **dual 10/100 Gbps ports directly
  onto Microsoft's routers**, no provider in the middle; you then carve
  circuits out of that port pair. For massive, sovereign, or MACsec-encrypted
  connectivity.
- **FastPath** — sends data-plane traffic **straight from the ExpressRoute
  gateway to the VM**, bypassing the gateway's own routing hop for lower
  latency and higher throughput. It changes the data path, not the control
  plane (BGP still runs on the gateway).

## Step 5 — Where ExpressRoute sits against the VPN gateways

The design-question core, and why Lab 3's BGP mattered:

- **Coexistence** — a VNet can hold **both** an ExpressRoute gateway and a VPN
  gateway. The classic pattern is **ExpressRoute as primary, S2S VPN as
  encrypted backup**; when both advertise the same prefixes over BGP, Azure
  prefers the ExpressRoute path. This is exactly the multi-path routing BGP
  (Lab 3) exists to arbitrate — static LNG routes cannot express "prefer ER,
  fail to VPN."
- **SLA** — a single circuit is not the SLA'd configuration; ExpressRoute's
  99.95% SLA assumes **two circuits in different peering locations** (or
  redundant links). Design answers that promise an SLA on one circuit are
  wrong.
- **Encryption** — ExpressRoute is private but **not encrypted by default**;
  when the requirement says "encrypted *and* private/high-throughput," the
  answer is IPsec-over-ExpressRoute (VPN gateway over private peering) or
  MACsec on ExpressRoute Direct — not "ExpressRoute alone."

## What you proved (on paper)

- An **ExpressRoute circuit** is a private path through a provider to the
  Microsoft edge — no IPsec, no tunnel; provisioned in two halves (you create
  it, the provider lights it via the service key).
- **Private peering** reaches your VNets (needs an **ExpressRoute-type**
  gateway); **Microsoft peering** reaches Microsoft public services; **public
  peering is retired**.
- **SKU** (Local/Standard/**Premium**-for-global) and **billing**
  (Metered/Unlimited) are independent choices; **Premium** is the reach +
  scale unlock.
- **Global Reach** = branch-to-branch over the backbone; **ER Direct** =
  your own ports, no provider; **FastPath** = gateway-bypass data path.
- ExpressRoute **coexists** with S2S VPN (ER primary + VPN backup, arbitrated
  by **BGP**), carries a 99.95% SLA **only with redundant circuits**, and is
  **not encrypted by default**.
