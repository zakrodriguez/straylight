# AZ-700 Private Access Labs — Design

**Date:** 2026-08-06
**Companion to:** MS Learn AZ-700 learning path, *Design and implement network
security* / *secure access to PaaS* (service endpoints, private endpoints,
Private Link, private DNS integration)
**Predecessor pattern:** `2026-08-06-az700-lb-labs-design.md` (lb module;
shipped v2.15.0) and `2026-07-25-az700-dns-labs-design.md` (dns module)

## Goal

Fifth exam domain: private access to Azure PaaS. The domain is really one
question asked four ways — **how do you keep traffic to a PaaS service (a
storage account, your own service) off the public internet?** — and the exam's
sharpest distinction is **service endpoint vs private endpoint**. Four labs:

1. **Service endpoints** — pin a PaaS service's public endpoint to a subnet
   over the Azure backbone, and lock its firewall to that subnet.
2. **Private endpoint to storage** — give the storage account a **private IP**
   in your VNet and resolve its public name to that private IP (private DNS).
3. **Private Link Service** — the provider side: expose *your own* service
   (behind an internal Standard LB) for others to reach by private endpoint.
4. **Hybrid private DNS** — make on-prem resolve those private endpoints over
   the S2S tunnel (ties the hybrid tunnel + DNS Private Resolver + PE together).

Net new: 4 labs + 4 quizzes + this spec + the module exam + one new Bicep
topology (`private-link`).

## MS Learn → lab mapping

| MS Learn topic | Lab | Tier |
|---|---|---|
| VNet service endpoints + PaaS firewall to a subnet | `az700-private-1-service-endpoints-walkthrough.md` | VERIFIABLE |
| Private endpoint to storage + private DNS integration | `az700-private-2-private-endpoint-storage-walkthrough.md` | VERIFIABLE |
| Private Link Service (provider side, internal LB frontend) | `az700-private-3-private-link-service-walkthrough.md` | RUNBOOK |
| Hybrid name resolution to private endpoints over the tunnel | `az700-private-4-hybrid-private-dns-walkthrough.md` | RUNBOOK |

## Deploy contract (locked)

### Labs 1 + 2 — `private-link` (one session, two labs)

One VNet with two subnets and a storage account, reused by both labs — the
same "share one deploy" pattern the dns and lb modules use. Lab 1 restricts the
storage account to a subnet with a **service endpoint**; Lab 2 goes further and
gives it a **private endpoint** with private-DNS resolution. The narrative is
deliberate: *restrict public access to a subnet, then remove public access
entirely.*

| Piece | Detail |
|---|---|
| VNet `vnet-plink` | `10.103.16.0/24` |
| `snet-workload` | `10.103.16.0/27` — the VM + the service-endpoint subject (Lab 1) |
| `snet-pe` | `10.103.16.32/27` — private endpoints (`privateEndpointNetworkPolicies` Disabled) (Lab 2) |
| `st<uniqueString>` | StorageV2 / Standard_LRS; name = `st${uniqueString(rg.id)}` (globally unique, deterministic per RG) |
| `vm-plink1` | B2ts_v2 in `snet-workload`, for the resolution/access proofs (`run-command`) |

Service endpoints and private endpoints legitimately **coexist** on one
account, so Lab 1's firewall lock and Lab 2's private endpoint sit on the same
storage account without conflict. Lab 2's last step tears the deployment down
(Lab 1 carries the "continuing? skip teardown" note, like lb-1 → lb-4).

### Lab 3 — Private Link Service (runbook)

A Private Link Service is the **provider** side of Private Link: you front your
service with an **internal Standard Load Balancer**, create a PLS over that
frontend (with a NAT subnet), and hand consumers an **alias** they target with
a private endpoint — with an **approval** workflow and visibility control. The
full value only appears with a **second (consumer) VNet + PE**, and the NAT/
approval mechanics are fiddly, so Lab 3 is a **runbook**: it deploys the
provider side against a documented `main.bicep`-shaped example and teaches the
model, the internal-LB requirement, the alias, and auto-approval. No golden.

### Lab 4 — Hybrid private DNS (runbook)

The capstone that ties three prior modules together: an **on-prem** host (`dc1`)
resolving an Azure **private endpoint** by its `privatelink.*` name **over the
S2S tunnel**. It needs `hybrid-vpn` (P3a), a **DNS Private Resolver** inbound
endpoint (P3b, dns-3), and a private endpoint (Lab 2) all standing at once —
expensive and multi-dependency — so it is a **runbook**: a conditional
forwarder on `dc1` → the resolver's inbound endpoint → the `privatelink` zones.
No golden.

## Cost table (locked)

| Lab | Metered pieces | Session estimate |
|---|---|---|
| 1 (service endpoints) | 1 × B2ts_v2 + a storage account (pennies) | < $0.25 |
| 2 (private endpoint) | reuses lab 1's deployment; 1 private endpoint (~$0.01/hr) + private DNS zone | ~$0 incremental |
| 3 (PLS) | runbook — internal Standard LB + PLS if the operator deploys it | operator's call |
| 4 (hybrid PE-DNS) | runbook — needs the gateway + resolver standing (see P3a/P3b costs) | operator's call |
| Labs 1 + 2, one sitting | | **< $0.30** |

## Verification model

Same as prior modules:

- Lab 1 asserts the **subnet's service endpoint** and the **storage network
  rules** (default action Deny + the allowed subnet) via `--query -o tsv`.
- Lab 2 asserts the **private endpoint** + the **private DNS zone group**, then
  the killer proof: `run-command` on `vm-plink1` resolves the storage account's
  **public** blob FQDN and gets back a **private** `10.103.16.x` address — the
  whole point of a private endpoint, observable.
- Storage account names and any public IPs are masked (`pubip`); the resolution
  proof asserts on the **private** address prefix (`10\.103\.16`), not a
  literal.
- Goldens ship as **skeletons**; live capture is a deferred paid session (the
  authored-first pattern the hybrid/P3b/P4 modules used) — two verifiable labs
  (private-1, private-2) capture; the two runbooks do not.
- az prints tsv booleans **lowercase**; expects are lowercase.

## Non-goals

- No second (consumer) VNet + PE for the Private Link Service flow (runbook).
- No standing tunnel/resolver for the hybrid resolution proof (runbook).
- No storage data-plane (containers/blobs/keys) — the labs assert **network**
  reachability and **name resolution**, not blob operations.
- No service endpoint policies, no PE for non-storage PaaS (Key Vault, SQL) —
  taught as prose; storage is the worked example.
