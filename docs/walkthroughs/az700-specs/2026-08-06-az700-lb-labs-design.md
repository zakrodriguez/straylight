# AZ-700 Load Balancing Labs — Design

**Date:** 2026-08-06
**Companion to:** MS Learn AZ-700 learning path, *Design and implement load
balancing and application delivery* (Azure Load Balancer, Application Gateway,
Traffic Manager, Azure Front Door)
**Predecessor pattern:** `2026-07-30-az700-p3b-labs-design.md` (hybrid 4–6 +
dns-3; shipped v2.14.0) and `2026-07-18-az700-vnet-labs-design.md` (vnet module)

## Goal

Fourth exam domain: load balancing and application delivery. Five labs walking
the four Azure load-balancing services and, critically, **when to reach for
each** — the distinction the exam tests hardest:

- **Azure Load Balancer** (Standard) — Layer 4 (TCP/UDP), regional, the
  frontend for VM backends.
- **Application Gateway** (Standard_v2) — Layer 7 (HTTP/S), regional, with
  URL-path and host routing, and the WAF host.
- **Web Application Firewall** — the OWASP rule engine that rides App Gateway
  (or Front Door), Detection vs Prevention.
- **Traffic Manager** — DNS-based global routing (it never sees a packet).
- **Azure Front Door** (Standard) — global Layer 7 with the Microsoft edge,
  caching, and its own WAF.

Net new: 5 labs + 5 quizzes + this spec + the module exam + two new Bicep
topologies (`lb-standard`, `appgw`) + one shared backend VM module
(`backendvm.bicep`).

## MS Learn → lab mapping

| MS Learn topic | Lab | Tier |
|---|---|---|
| Azure Load Balancer: SKUs, frontend, backend pool, health probe, rules | `az700-lb-1-standard-load-balancer-walkthrough.md` | VERIFIABLE |
| Application Gateway: listeners, backend pools, URL-path routing | `az700-lb-2-application-gateway-routing-walkthrough.md` | VERIFIABLE (Part A/B) |
| Web Application Firewall: OWASP CRS, custom rules, Detection/Prevention | `az700-lb-3-web-application-firewall-walkthrough.md` | RUNBOOK |
| Traffic Manager: routing methods, endpoints, DNS-based global routing | `az700-lb-4-traffic-manager-walkthrough.md` | VERIFIABLE |
| Azure Front Door: origins, routes, caching, edge WAF | `az700-lb-5-front-door-walkthrough.md` | RUNBOOK/PAPER |

## Deploy contract (locked)

Two new topologies, three deploy shapes:

### Labs 1 + 4 — `lb-standard` (one session, two labs)

A public **Standard Load Balancer** fronting **two backend VMs** that each run
a tiny hostname web server (so the LB genuinely distributes and can be proven
with `curl`). Lab 1 dissects the LB (SKU, frontend, backend pool, health
probe, rules) and curls the frontend to see distribution. **Lab 4 (Traffic
Manager) reuses this same deployment** — it creates a Traffic Manager profile
by lab steps (the profile + endpoints *are* the exam skill, so they belong in
steps, not the topology) and points an endpoint at this LB's public IP, then
resolves the `*.trafficmanager.net` name. Labs 1 + 4 run back-to-back on one
`deploy lb-standard`.

The backend web server is **`python3 -m http.server`-style, seeded by
cloud-init** — no package install, so the backend VMs need no outbound
internet (Standard LB backends have none by default). An NSG allows HTTP :80
from the internet (frontend flow) and from `AzureLoadBalancer` (health probes).

| Piece | Detail |
|---|---|
| VNet `vnet-lb` | `10.103.12.0/24`, `snet-backend` `10.103.12.0/27` |
| `lbpip-straylight` | Standard, static, zone-redundant |
| `lb-straylight` | Standard; frontend (pip), `bepool` (2 NICs), HTTP probe :80, LB rule 80→80 |
| `vm-lb1`, `vm-lb2` | B2ts_v2, cloud-init hostname web server on :80 |

### Lab 2 — `appgw` (Part A deploy + watch, Part B hands-on)

Application Gateway **provisions in ~15–20 minutes**, so — following the
track's rule for long-running resources — it is deployed by `az700.sh`, never
inside a lab step; Lab 2 gates on `az700.sh watch appgw` (Part A) then inspects
and exercises the routing (Part B). The gateway carries a **URL-path map**:
`/images/*` to one backend pool, everything else to another, proven by
curling the gateway's public IP with and without the path.

| Piece | Detail |
|---|---|
| VNet `vnet-appgw` | `10.103.13.0/24` |
| `snet-appgw` | `10.103.13.0/26` — dedicated to the gateway (App Gateway requires its own subnet) |
| `snet-backend` | `10.103.13.64/27` |
| `agw-straylight` | Standard_v2, capacity 1 (the cost floor); listener :80, 2 backend pools, path-based rule |
| `vm-appgw1`, `vm-appgw2` | B2ts_v2, hostname web server on :80 (pool members) |

### Lab 3 — WAF (runbook, references `appgw`)

WAF runs on the **WAF_v2** App Gateway tier (or a Front Door). Standing up a
separate WAF-tier gateway is pricey and slow, and WAF behaviour (rule matches,
blocked requests) is latency- and signature-dependent — so Lab 3 is a
**runbook**: it teaches the WAF policy model (managed OWASP CRS, custom rules,
Detection vs Prevention, exclusions) against the `appgw` topology and documents
attaching a `Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies`
and flipping the SKU to WAF_v2. No golden.

### Lab 5 — Azure Front Door (runbook)

Front Door is **global and edge-latency-dependent** (propagation to the
Microsoft POPs takes minutes and varies), so — exactly as the plan scoped the
latency-flaky services — Lab 5 is a **runbook**: origins, origin groups,
routes, caching, rules engine, the built-in WAF, and the Front-Door-vs-Traffic
Manager-vs-App-Gateway decision. No golden.

## Cost table (locked)

| Lab | Metered pieces | Session estimate |
|---|---|---|
| 1 (Std LB) | 2 × B2ts_v2 + Standard LB (~$0.025/hr) + 1 Standard pip | < $0.30 |
| 4 (Traffic Manager) | reuses lab 1's deployment; TM profile ~$0.54/mo prorated + queries | ~$0 incremental |
| 2 (App Gateway) | AppGW Standard_v2 (~$0.25/hr + capacity units) + 2 × B2ts_v2 + pip; ~20-min provision | < $0.60 |
| 3 (WAF) | runbook — only if the operator stands up WAF_v2 (~$0.36/hr) | operator's call |
| 5 (Front Door) | runbook — Front Door Standard base + routes | operator's call |
| Whole module, two sittings (lb-standard, then appgw) | | **~$0.90** |

App Gateway is the module's cost driver and the one to remember to destroy:
`destroy appgw` the same day.

## Verification model

Same as prior modules:

- Verifiable labs assert `--query <JMESPath> -o tsv` config projections **and**
  a live proof where cheap: Lab 1 curls the LB frontend and gets a backend
  hostname; Lab 2 curls the gateway with/without `/images/` and sees the path
  map choose pools; Lab 4 asserts the TM profile config and resolves the
  `*.trafficmanager.net` name.
- Public IPs (the LB, gateway, and TM-target addresses) never appear as
  literals — the `pubip` normalizer masks them; the curl proofs assert on the
  **backend hostname** (`vm-lb[12]`, `vm-appgw[12]`) or on a routing outcome,
  not the address.
- Long-running App Gateway is deployed by the script; Lab 2 gates on
  `az700.sh watch appgw` (never provisions in a step).
- Goldens ship as **skeletons**; live capture is a deferred paid session (the
  authored-first pattern the hybrid and P3b modules used) — three verifiable
  labs (lb-1, lb-2, lb-4) capture, the two runbooks do not.
- az prints tsv booleans **lowercase**; expects are lowercase.

## Non-goals

- No internal (private) Load Balancer variant deployed — taught as prose
  against the public one (frontend is the only difference).
- No WAF_v2 gateway or Front Door profile deployed (cost + latency) — both
  runbook.
- No TLS/SSL termination or certificate wiring on App Gateway (the PKI labs own
  certificates; here the listener is HTTP :80 to keep the routing the subject).
- No cross-region LB, Gateway Load Balancer, or NVA insertion.
