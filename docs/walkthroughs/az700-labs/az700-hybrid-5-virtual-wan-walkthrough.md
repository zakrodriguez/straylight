# AZ-700 Hybrid Lab 5 — Virtual WAN

The vnet module built a hub-and-spoke by hand: you created the hub, peered
each spoke, wrote the UDRs, and stood up an NVA to force transit. **Virtual
WAN** is Microsoft's managed version of that pattern — a **virtual hub** whose
router Microsoft operates, giving **automatic any-to-any transit** between
every VNet, VPN branch, ExpressRoute circuit, and P2S client attached to it,
with no peering mesh and no hand-written routes. This lab is a **runbook**:
the virtual hub takes ~30 minutes to provision and carries a
routing-infrastructure cost, so it is not part of the verified set. Deploy it
if you want the hands-on reps; otherwise read for the model, which is what the
exam tests.

Pairs with MS Learn: *Design and implement hybrid connectivity* — Azure
Virtual WAN (AZ-700 learning path).

> **Runbook lab (no walkverify golden)**: commands below are shown with the
> shapes to expect, not asserted. The virtual hub provisions in **~30 min**
> and the hub's routing infrastructure meters at **~$0.25/hr** plus per
> connection and per GB — this is the module's second-most-expensive lab
> after the S2S gateway. **Destroy it the same day**:
> `azure/scripts/az700.sh destroy vwan-lite`.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| az CLI ≥ 2.60, logged in | every command is `az` from the host |
| Willingness to wait ~30 min and spend ~$0.60 for a sitting | the virtual hub is slow and metered |
| Verification: RUNBOOK (no golden, no `@verify`) | latency + cost make replay a judgment call, not a CI/gate step |

## The model, before the commands

| | Hub-and-spoke (vnet module) | Virtual WAN (this lab) |
|---|---|---|
| Hub router | you build it (VNet + NVA/UDRs) | **Microsoft-managed** virtual hub |
| Spoke-to-spoke transit | manual: peering + UDR + NVA hop | **automatic any-to-any** (Standard) |
| Branch (S2S/P2S) attach | a gateway you manage in the hub | a **hub gateway** vWAN provisions for you |
| Scale-out to many regions | mesh of hubs you peer | multiple hubs, **hub-to-hub automatic** (Standard) |
| Security inspection | your NVA / firewall + UDRs | **secured hub**: Azure Firewall + **routing intent** |

Two dials define a vWAN: the **vWAN type** and, per hub, whether it is
**secured**.

- **Basic vs Standard vWAN** — **Basic** does S2S VPN only, no hub-to-hub, no
  ExpressRoute, no any-to-any. **Standard** unlocks hub-to-hub transit,
  ExpressRoute, P2S, and inter-hub any-to-any. New designs are Standard;
  Basic exists mostly to be the wrong answer.
- **Secured virtual hub** — deploy **Azure Firewall into the hub** and set
  **routing intent** (send *private* traffic, *internet* traffic, or both to
  the firewall). Routing intent is what makes every any-to-any flow traverse
  the firewall **without** you writing a single UDR — the managed-hub analogue
  of the vnet module's NVA-plus-UDR forcing.

## Runbook — deploy a minimal Standard vWAN

Deploy the `vwan-lite` topology (a Standard vWAN + one virtual hub + a spoke
VNet connection). The `--no-wait` deploy returns immediately; the hub is the
slow part.

```bash
azure/scripts/az700.sh deploy vwan-lite --no-wait
azure/scripts/az700.sh watch vwan-lite        # ~30 min: the virtual hub
```

What the topology creates:

- `vwan-straylight` — a **Standard** `virtualWan`.
- `vhub1` — a `virtualHub`, address prefix `10.103.8.0/23` (a hub wants a
  dedicated `/23`; it is Microsoft-managed, so you never subnet it yourself).
- `vnet-vwan-spoke1` (`10.103.10.0/24`) + a **hub VNet connection** binding it
  to `vhub1`.

## Runbook — read the managed hub

Once `watch` shows `Succeeded`, inspect the pieces:

```bash
RG=rg-straylight-az700-vwan-lite

# The vWAN and its type
az network vwan show --resource-group $RG --name vwan-straylight \
  --query "{type:type, sku:sku}" -o json
#   Expect: type "Standard"

# The hub, its routing state, and its address prefix
az network vhub show --resource-group $RG --name vhub1 \
  --query "{state:routingState, prefix:addressPrefix, sku:sku}" -o json
#   Expect: routingState "Provisioned", addressPrefix "10.103.8.0/23"

# The VNet connection into the hub
az network vhub connection list --resource-group $RG --vhub-name vhub1 \
  --query "[].{name:name, remote:remoteVirtualNetwork.id}" -o json
#   Expect: one connection, remote = vnet-vwan-spoke1

# The hub's effective routes — the any-to-any table Microsoft maintains
az network vhub get-effective-routes --resource-group $RG --name vhub1 \
  --resource-type RouteTable \
  --resource-id $(az network vhub route-table show -g $RG --vhub-name vhub1 \
    --name defaultRouteTable --query id -o tsv) -o table
#   Expect: the spoke's prefix present with no UDR you wrote — the hub router
#           learned it automatically. That automatic table is the whole point.
```

The `defaultRouteTable` shows spoke prefixes appearing **without any UDR you
authored** — the contrast with the vnet module, where every transit route was
hand-written. Add a second VNet connection and its prefix shows up for the
first spoke automatically: **any-to-any, managed**.

## Runbook — tear it down

```bash
azure/scripts/az700.sh destroy vwan-lite       # do this the same day
```

## What you proved (runbook)

- Virtual WAN is the **managed** hub-and-spoke: a **Microsoft-operated virtual
  hub** with **automatic any-to-any** transit — no peering mesh, no
  hand-written transit UDRs.
- **Standard** vWAN unlocks hub-to-hub, ExpressRoute, P2S, and inter-hub
  any-to-any; **Basic** is S2S-only and rarely the right answer.
- A **secured virtual hub** (Azure Firewall + **routing intent**) forces
  inspection across all flows without UDRs — the managed analogue of the vnet
  module's NVA-plus-UDR pattern.
- The hub's `defaultRouteTable` carries connected prefixes **automatically**;
  that managed route table is the reason to choose vWAN over a self-built hub
  when the topology spans many VNets, regions, and branches.
