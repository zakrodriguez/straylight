# AZ-700 VNet Lab 1 — Address Space, Subnets, and Reserved Names

Every Azure network decision starts with address space, and most production
regrets start with getting it wrong. This lab reads the address plan of a
deployed hub-spoke estate, then builds and dissects a scratch VNet by hand:
subnets, the five addresses Azure silently reserves in every one of them, the
reserved subnet *names* (`GatewaySubnet` and friends), and what an
overlapping-prefix mistake actually looks like at the CLI.

Pairs with MS Learn: *Introduction to Azure virtual networks* — plan virtual
networks, plan IP addressing (AZ-700 learning path, Design and implement core
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
> Labs 1–3 of this module share that one deployment — run them back-to-back
> in a single session and tear down once at the end.
>
> **Cost**: < $0.25 for the session (one B2ts_v2 VM; VNets and subnets are free).
> **Teardown when done**: `azure/scripts/az700.sh destroy hub-spoke`
> (Step 6 — skip it only if you are continuing to Lab 2 in the same sitting).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Azure subscription + az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `azure/scripts/az700.sh deploy hub-spoke` run this session | provides the RG, vnet-hub, vnet-spoke1/2, vm-spoke1 |
| Azure spend this session: < $0.25 | one B2ts_v2; nothing hourly-expensive |
| Teardown: `az700.sh destroy hub-spoke` (Step 6) | same-day teardown is the track's budget model |
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

## Step 1 — Read the deployed address plan

The track's whole Azure estate draws from `10.100.0.0/14` (see
STRAYLIGHT-REFERENCE.md, *Azure conventions*). List what the deploy created:

<!-- @verify host=lab step=list-vnets expect=/vnet-hub/ expect=/vnet-spoke1/ expect=/vnet-spoke2/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet list --resource-group $RG \
  --query "[].{name:name, space:addressSpace.addressPrefixes[0]}" -o tsv
# Expected: vnet-hub 10.100.0.0/22, vnet-spoke1 10.101.0.0/24, vnet-spoke2 10.102.0.0/24
```

An **address space** is what the VNet owns; **subnets** carve it up. The hub
carves its /22 three ways — note the first subnet's *name*:

<!-- @verify host=lab step=hub-subnets expect=/GatewaySubnet/ expect=/snet-dns/ expect=/snet-shared/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet show --resource-group $RG --name vnet-hub \
  --query "subnets[].{name:name, prefix:addressPrefix}" -o tsv
# Expected: GatewaySubnet 10.100.0.0/27, snet-dns 10.100.1.0/24, snet-shared 10.100.2.0/24
```

`GatewaySubnet` is not a naming convention — it is a **reserved name**. A VPN
or ExpressRoute gateway will only deploy into a subnet with exactly that
name. The other reserved names you must recognize for the exam:
`AzureFirewallSubnet`, `AzureBastionSubnet` (minimum /26, enforced when
Bastion deploys), and `RouteServerSubnet` (minimum /27). None of these carry
an NSG in the hub template — GatewaySubnet must not have one.

## Step 2 — Build a scratch VNet by hand

Create a throwaway VNet inside the same RG. It comes from the track's
`10.100.0.0/14` pool but outside the deployed VNets' space, so nothing can
collide:

<!-- @verify host=lab step=create-vnet expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet create --resource-group $RG --name vnet-lab1 \
  --address-prefixes 10.103.0.0/24 \
  --subnet-name snet-a --subnet-prefixes 10.103.0.0/26 \
  --query newVNet.provisioningState -o tsv
# Expected: Succeeded
```

Add a second subnet — subnets can be added to a live VNet at any time, as
long as the prefix fits inside the address space and overlaps nothing:

<!-- @verify host=lab step=create-subnet-b expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet subnet create --resource-group $RG --vnet-name vnet-lab1 \
  --name snet-b --address-prefixes 10.103.0.64/26 \
  --query provisioningState -o tsv
# Expected: Succeeded
```

## Step 3 — The five addresses you never get

A /26 has 64 addresses; Azure hands you 59. In **every** subnet Azure
reserves the network address, the last (broadcast) address, and the first
three usable ones (`.1` default gateway, `.2`/`.3` Azure DNS mapping). Prove
it — ask Azure whether specific addresses in `snet-a` are assignable:

<!-- @verify host=lab step=reserved-ip expect=/false/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet check-ip-address --resource-group $RG --name vnet-lab1 \
  --ip-address 10.103.0.1 --query available -o tsv
# Expected: false   (.1 is the subnet's default gateway — reserved)
```

<!-- @verify host=lab step=usable-ip expect=/true/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet check-ip-address --resource-group $RG --name vnet-lab1 \
  --ip-address 10.103.0.10 --query available -o tsv
# Expected: true    (.10 is the sixth address — first assignable is .4)
```

Exam arithmetic: *usable addresses = 2^(32−prefix) − 5*. A /29 yields 3, a
/28 yields 11, a /24 yields 251. When a question asks for the smallest subnet
that fits N VMs, add the five before you size.

## Step 4 — Reserved names in your own VNet

Reserved subnet names work in any VNet. Give the scratch VNet a
`GatewaySubnet` at the recommended /27 (the hard minimum is /29, but /27
leaves room for gateway SKU growth and ExpressRoute coexistence):

<!-- @verify host=lab step=create-gwsubnet expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet subnet create --resource-group $RG --vnet-name vnet-lab1 \
  --name GatewaySubnet --address-prefixes 10.103.0.128/27 \
  --query provisioningState -o tsv
# Expected: Succeeded
```

## Step 5 — What an overlap failure looks like

Try to add a subnet whose prefix collides with `snet-a` (10.103.0.0/26
covers .0–.63; the /27 below claims .32–.63):

```bash
RG=rg-straylight-az700-hub-spoke
az network vnet subnet create --resource-group $RG --vnet-name vnet-lab1 \
  --name snet-oops --address-prefixes 10.103.0.32/27 -o table
# Expected: ERROR — NetcfgSubnetRangesOverlap: Subnet 'snet-oops' is not valid
# because its IP address range overlaps with that of an existing subnet.
```

(Unannotated on purpose: error text shifts across az versions. Read the
error code — `NetcfgSubnetRangesOverlap` — that code family is exam
material.) The same rule applies one level up: two VNets *may* hold
overlapping address spaces, but they can then never be peered or connected —
which is why the track pre-plans everything under one /14.

Clean up the scratch VNet; the deployed estate is untouched:

<!-- @verify host=lab step=delete-scratch expect=/^0$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet delete --resource-group $RG --name vnet-lab1
az network vnet list --resource-group $RG \
  --query "length([?name=='vnet-lab1'])" -o tsv
# Expected: 0
```

## Step 6 — Teardown

**Continuing to Lab 2 in this sitting? Skip this step** — it ends the whole
module session.

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy hub-spoke
# Expected: "delete submitted for rg-straylight-az700-hub-spoke (async)"
```

The resource group is the state: everything this lab created by hand
(vnet-lab1 would have gone too, had we kept it) dies with the group. Confirm
later with `azure/scripts/az700.sh list` or
`az group list --tag track=az700 -o table`.

## What you proved

- The deployed estate follows a pre-planned, collision-free address plan
  under `10.100.0.0/14`.
- Subnets are carved live from a VNet's space; every subnet silently loses
  five addresses.
- `GatewaySubnet` (and friends) are reserved *names* with size floors, not
  conventions.
- Overlapping prefixes fail at creation with `NetcfgSubnetRangesOverlap` —
  and overlapping VNets can never be peered, which is next lab's subject.
