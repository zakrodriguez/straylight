# AZ-700 VNet Lab 2 — Hub-and-Spoke Peering and Non-Transitivity

Lab 1 read the address plan; this lab wires the topology together. The
deploy leaves the hub and both spokes deliberately unpeered. You create
every peering by hand, watch the `peeringState` lifecycle from `Initiated`
to `Connected`, and then walk into the exam's favorite trap: a spoke that
can reach the hub but not the other spoke, because peering is
non-transitive. The effective route table on the test VM's NIC is the
evidence at every stage — routes appear and fail to appear exactly when
the peering model says they should.

Pairs with MS Learn: *Introduction to Azure virtual networks* — configure
virtual network peering (AZ-700 learning path, Design and implement core
networking infrastructure).

> **Before you start**: no Straylight VMs are needed (azure-only lab). You
> need an Azure subscription with az CLI logged in and the module's topology
> deployed:
>
> ```bash
> az account show --query id -o tsv          # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy hub-spoke    # hub + 2 spokes + 1 B2ts_v2 VM (~2 min)
> ```
>
> Labs 1–3 of this module share that one deployment — if you just finished
> Lab 1 in this sitting, it is already up (the deploy is idempotent if you
> run it anyway).
>
> **Cost**: < $0.25 for the session (one B2ts_v2 VM; peerings are ~free at lab
> traffic volume). **Teardown when done**:
> `azure/scripts/az700.sh destroy hub-spoke` (Step 7 — skip it only if you
> are continuing to Lab 3 in the same sitting).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Azure subscription + az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `azure/scripts/az700.sh deploy hub-spoke` run this session | provides the RG, vnet-hub, vnet-spoke1/2, vm-spoke1 |
| Azure spend this session: < $0.25 | one B2ts_v2; peerings ~free at lab traffic volume |
| Teardown: `az700.sh destroy hub-spoke` (Step 7) | same-day teardown is the track's budget model |
| Verification: VERIFIABLE (walkverify golden) | pure az CLI with `-o tsv` projections |

## Setup (one-time, idempotent)

Every code block in this lab is self-contained — each one names the resource
group itself, so any block can be re-run standalone. Confirm the deployment
finished:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded   (anything else: run azure/scripts/az700.sh deploy hub-spoke)
```

## Step 1 — Prove nothing is peered

The deploy creates the VNets but no peerings — a hub-and-spoke in name
only. Count the hub's peerings:

<!-- @verify host=lab step=no-peerings expect=/^0$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet peering list --resource-group $RG --vnet-name vnet-hub \
  --query "length(@)" -o tsv
# Expected: 0
```

Now read what `vm-spoke1`'s NIC actually knows. Every NIC starts with
three kinds of system routes: the VNet's own prefix (here 10.101.0.0/24)
with next hop **VirtualNetwork**, the default route 0.0.0.0/0 with next
hop **Internet**, and the RFC 1918 ranges with next hop **None** —
silently dropped, so private traffic never leaks out the Internet path.
Peering adds routes on top of these; before any peering exists, there are
none to find:

<!-- @verify host=lab step=no-peering-routes expect=/^0$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 --query \
  "length(value[?nextHopType=='VNetPeering'])" -o tsv
# Expected: 0   (only system routes; the hub's 10.100.0.0/22 hits the None route)
```

Right now a packet from vm-spoke1 to any 10.100.x.x address matches the
RFC 1918 → None route and is dropped. Peering will change that.

## Step 2 — One-way peering is half a peering

A peering is not one object — it is two unidirectional resources, each
living inside the VNet it points *from*. Create only the hub's half and
inspect its state:

<!-- @verify host=lab step=one-way-peering expect=/Initiated/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet peering create --resource-group $RG --name hub-to-spoke1 \
  --vnet-name vnet-hub --remote-vnet vnet-spoke1 \
  --allow-vnet-access --allow-forwarded-traffic -o none
az network vnet peering show --resource-group $RG --vnet-name vnet-hub \
  --name hub-to-spoke1 --query peeringState -o tsv
# Expected: Initiated
```

`Initiated` is the waiting state: this side is configured, the reverse
resource does not exist yet, and **no traffic flows**. The lifecycle is
`Initiated` → `Connected`, and it only advances when the matching peering
appears in the remote VNet. Exam questions love a topology stuck at
`Initiated` — the fix is always the same: create the missing direction.

The two flags are worth reading now: `--allow-vnet-access` permits traffic
between the peered VNets at all (it maps to `allowVirtualNetworkAccess`),
and `--allow-forwarded-traffic` accepts packets the remote VNet
*forwarded* rather than originated — irrelevant today, required the moment
an NVA or gateway forwards traffic between VNets on your behalf (Lab 3
builds the NVA-plus-UDR half of that pattern inside one VNet).

## Step 3 — Complete the pair, then peer spoke2

Create the reverse resource inside vnet-spoke1 and watch the hub's half
flip state without being touched:

<!-- @verify host=lab step=complete-spoke1 expect=/Connected/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet peering create --resource-group $RG --name spoke1-to-hub \
  --vnet-name vnet-spoke1 --remote-vnet vnet-hub \
  --allow-vnet-access --allow-forwarded-traffic -o none
az network vnet peering show --resource-group $RG --vnet-name vnet-hub \
  --name hub-to-spoke1 --query peeringState -o tsv
# Expected: Connected
```

Both directions exist, both report `Connected`, and traffic between hub
and spoke1 now flows. Repeat for spoke2 — both directions in one go:

<!-- @verify host=lab step=peer-spoke2 expect=/Connected/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet peering create --resource-group $RG --name hub-to-spoke2 \
  --vnet-name vnet-hub --remote-vnet vnet-spoke2 \
  --allow-vnet-access --allow-forwarded-traffic -o none
az network vnet peering create --resource-group $RG --name spoke2-to-hub \
  --vnet-name vnet-spoke2 --remote-vnet vnet-hub \
  --allow-vnet-access --allow-forwarded-traffic -o none
az network vnet peering show --resource-group $RG --vnet-name vnet-hub \
  --name hub-to-spoke2 --query peeringState -o tsv
# Expected: Connected
```

The classic hub-and-spoke is now standing: hub↔spoke1 and hub↔spoke2,
four peering resources total.

## Step 4 — The non-transitivity trap

The peerings did something concrete to vm-spoke1's NIC: they programmed
routes with next hop `VNetPeering`. (Their *source* reads `Default` —
peering routes are system-programmed; the next-hop type is what marks
them.) The hub's entire /22 is now reachable:

<!-- @verify host=lab step=route-to-hub expect=/^1$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 --query \
  "length(value[?nextHopType=='VNetPeering' && addressPrefix[0]=='10.100.0.0/22'])" \
  -o tsv
# Expected: 1   (the hub's whole address space, one peering route)
```

Both spokes peer with the hub, so intuition says spoke1 can reach spoke2
through it. Ask the route table:

<!-- @verify host=lab step=no-route-to-spoke2 expect=/^0$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 --query \
  "length(value[?nextHopType=='VNetPeering' && addressPrefix[0]=='10.102.0.0/24'])" \
  -o tsv
# Expected: 0   (no route to spoke2 — peering is non-transitive)
```

Peering is **non-transitive**: a peering programs routes only for the two
VNets it directly joins. Spoke1 learned the hub's prefix and nothing
beyond it — 10.102.0.0/24 still falls through to the RFC 1918 → None
route. Nothing in the hub forwards between spokes either: there is no
router VM, no gateway, and `allowForwardedTraffic` only *permits*
forwarded packets to arrive — it creates no routes and forwards nothing
itself. Two hops through the hub simply do not happen.

## Step 5 — Three fixes, apply the simplest

The exam expects you to name all three ways to get spoke-to-spoke
traffic:

1. **Direct spoke-to-spoke peering** — simplest, but a full mesh needs
   n(n−1)/2 peerings as spoke count grows.
2. **An NVA in the hub plus UDRs** in each spoke pointing spoke prefixes
   at it — Lab 3 builds exactly this.
3. **A hub gateway with gateway transit** (`allowGatewayTransit` /
   `useRemoteGateways`) — the hybrid module's territory.

Apply the simplest one — peer the spokes directly, both directions in one
block:

<!-- @verify host=lab step=peer-spokes-direct expect=/Connected/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet peering create --resource-group $RG --name spoke1-to-spoke2 \
  --vnet-name vnet-spoke1 --remote-vnet vnet-spoke2 --allow-vnet-access -o none
az network vnet peering create --resource-group $RG --name spoke2-to-spoke1 \
  --vnet-name vnet-spoke2 --remote-vnet vnet-spoke1 --allow-vnet-access -o none
az network vnet peering show --resource-group $RG --vnet-name vnet-spoke1 \
  --name spoke1-to-spoke2 --query peeringState -o tsv
# Expected: Connected
```

The route the hub never provided appears immediately:

<!-- @verify host=lab step=route-to-spoke2 expect=/^1$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 --query \
  "length(value[?nextHopType=='VNetPeering' && addressPrefix[0]=='10.102.0.0/24'])" \
  -o tsv
# Expected: 1   (direct peering programs the route transit never would)
```

## Step 6 — Read the transit knobs for later

Every peering carries two more flags this lab left at their defaults.
Read them on the hub's side:

<!-- @verify host=lab step=gateway-transit-flag expect=/false/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet peering show --resource-group $RG --vnet-name vnet-hub \
  --name hub-to-spoke1 --query allowGatewayTransit -o tsv
# Expected: false
```

In the hybrid module, `allowGatewayTransit` on the hub's side of a
peering offers the hub's VPN or ExpressRoute gateway to the spoke, and
`useRemoteGateways` on the spoke's side consumes it — spokes then reach
on-premises through the hub without gateways of their own. The two flags
can never both be true on the same side of a peering: one side offers a
gateway, the other uses it, never both at once. That is why the hub's
GatewaySubnet from Lab 1 exists and stays empty for now.

## Step 7 — Teardown

**Continuing to Lab 3 in this sitting? Skip this step** — it ends the
whole module session, and Lab 3 reuses the topology (peerings included).

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy hub-spoke
# Expected: "delete submitted for rg-straylight-az700-hub-spoke (async)"
```

The resource group is the state: all six peering resources die with
their VNets when the group goes. Confirm later with
`azure/scripts/az700.sh list` or `az group list --tag track=az700 -o table`.

## What you proved

- A peering is two unidirectional resources, one per VNet; traffic flows
  only once both exist and each reports `peeringState` = `Connected`.
- Peering does its work in the route table: `VNetPeering` next-hop
  routes (source `Default`) for the remote prefix appear on every NIC
  the moment a pair connects.
- Peering is non-transitive — spoke1 never learned spoke2's prefix
  through the hub, and `allowForwardedTraffic` alone creates no routes
  and forwards no traffic.
- Spoke-to-spoke reachability takes direct peering (done here), an NVA
  plus UDRs (Lab 3), or hub gateway transit via `allowGatewayTransit` /
  `useRemoteGateways` (hybrid module).
