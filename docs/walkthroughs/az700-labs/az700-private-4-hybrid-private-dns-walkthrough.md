# AZ-700 Private Lab 4 — Hybrid Name Resolution to Private Endpoints

A private endpoint (Lab 2) is only useful to a client that can **resolve** its
`privatelink.*` name to the private IP. Inside the VNet that is automatic. But
the exam's hardest private-access scenario is **on-premises** reaching an Azure
private endpoint **over the S2S tunnel** — where on-prem DNS knows nothing about
Azure's private zones. This lab is the capstone that ties three modules
together: the **hybrid tunnel** (module 3), the **DNS Private Resolver**
(dns-3), and a **private endpoint** (Lab 2). It is a **runbook**: it needs all
three standing at once (real gateway + resolver cost), so it documents the
wiring rather than asserting it.

Pairs with MS Learn: *Secure access to PaaS* + *name resolution* — private
endpoint DNS in hybrid scenarios (AZ-700 learning path).

> **Runbook lab (no walkverify golden)**. This needs `hybrid-vpn` (P3a), the
> `dns-private-resolver` (dns-3), and a private endpoint (Lab 2) all deployed
> and the tunnel established — an expensive, multi-resource session. Read for
> the model; stand it up only for a full hands-on rep.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Lab 2 concepts (private endpoint, `privatelink` zones) | on-prem must resolve those zone names |
| Hybrid module (S2S tunnel) + dns-3 (Private Resolver) | the resolver is the bridge on-prem forwards to over the tunnel |
| Verification: RUNBOOK (no golden, no `@verify`) | needs gateway + resolver + PE standing simultaneously |

## The problem, stated precisely

- Inside the VNet, `account.blob.core.windows.net` resolves to the PE's private
  IP because the **`privatelink.blob.core.windows.net`** zone is linked to that
  VNet (Lab 2).
- **On-prem** (`dc1`) has no idea that zone exists. Point on-prem straight at
  Azure's wire server (`168.63.129.16`) and it fails — that address is only
  reachable *from inside* Azure, not across the tunnel.
- So on-prem needs a resolver **inside Azure** it can forward to, and that
  resolver must see the private zones. That is exactly the **DNS Private
  Resolver inbound endpoint** from dns-3.

## The wiring (three pieces, one path)

```
 dc1 (on-prem)                Azure                                   private endpoint
 ─────────────    S2S tunnel   ─────────────────────────────────────  ───────────────
 conditional  ───────────────▶ Private Resolver ──▶ privatelink.blob  ──▶ 10.x (the PE)
 forwarder                     inbound endpoint      zone (linked to
 for the                       (a private IP in       the resolver VNet)
 privatelink zone              10.103.4.0/28)
```

1. **Link the `privatelink.blob.core.windows.net` zone to the resolver's VNet**
   (or peer the PE VNet and resolver VNet and link the zone to both), so the
   resolver can answer for it.
2. **On `dc1`, add a conditional forwarder** for
   `privatelink.blob.core.windows.net` (and the other `privatelink.*` zones you
   use) pointing at the **inbound endpoint's private IP** (dns-3, Step 2).
3. Traffic path: `dc1` forwards the query across the **tunnel** to the inbound
   endpoint → the resolver answers from the linked **private zone** → on-prem
   gets the PE's **private IP** and connects to it over the tunnel.

## Runbook — the on-prem conditional forwarder

```powershell
# On dc1 (Windows DNS): forward the Azure private-endpoint zone to the resolver
# inbound endpoint (substitute the inbound endpoint IP from dns-3 Step 2).
Add-DnsServerConditionalForwarderZone `
  -Name "privatelink.blob.core.windows.net" `
  -MasterServers 10.103.4.4 `
  -ReplicationScope "Forest"

# Verify from dc1 — the public storage name should now resolve to the PE's
# PRIVATE IP, across the tunnel:
Resolve-DnsName myaccount.blob.core.windows.net
#   Expect: an A record in the private-endpoint range (10.103.16.x), reached
#           over the S2S tunnel — on-prem now talks to Azure PaaS privately.
```

## The exam framing

- **Never** hand on-prem the Azure wire server (`168.63.129.16`) — it is not
  reachable across VPN/ExpressRoute. On-prem forwards to a **resolver inbound
  endpoint** (or a DNS-forwarder VM) that lives in Azure.
- The **zone name is fixed** per service (`privatelink.blob.core.windows.net`,
  `privatelink.database.windows.net`, …) — memorise that these exist and that a
  private endpoint + the matching `privatelink` zone are always a pair.
- The **direction matters**: Lab 4 is on-prem → Azure (forward the
  `privatelink` zone to the inbound endpoint). Azure → on-prem (resolving a
  corporate zone) is the **outbound** endpoint + ruleset from dns-3.

## What you learned (runbook)

- On-prem resolving an Azure **private endpoint** needs a resolver **inside
  Azure** to forward to — the **DNS Private Resolver inbound endpoint** — never
  the wire server directly.
- The bridge is a **conditional forwarder** on `dc1` for the
  **`privatelink.*`** zone, pointing at the inbound endpoint IP, carried over
  the **S2S tunnel**.
- This is the capstone of the private-access domain: **private endpoint** (Lab
  2) + **Private Resolver** (dns-3) + **S2S tunnel** (module 3) compose into
  end-to-end private, hybrid PaaS access.
