# AZ-700 VNet Lab 3 — System Routes, UDRs, and an NVA Next Hop

Azure gives every subnet a working route table you never wrote — and the
moment you need traffic to flow through a firewall instead of around it, you
have to override that table without breaking it. This lab reads the system
routes on a deployed VM's NIC, builds a network virtual appliance (NVA) from
a plain B2ts_v2 VM, enables fabric-level IP forwarding, writes a user-defined
route (UDR) that steers spoke-to-spoke traffic through the NVA, and then
watches the override land in the effective route table.

Pairs with MS Learn: *Introduction to Azure virtual networks* — system
routes, custom routes, and network virtual appliances (AZ-700 learning path,
Design and implement core networking infrastructure).

> **Before you start**: no Straylight VMs are needed (azure-only lab). You
> need an Azure subscription with az CLI logged in and the module's topology
> deployed:
>
> ```bash
> az account show --query id -o tsv          # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy hub-spoke    # hub + 2 spokes + 1 B2ts_v2 VM (~2 min)
> ```
>
> Labs 1–3 of this module share that one deployment. This lab works whether
> or not you ran Lab 2 first — peerings add routes, but every assertion here
> filters on its own route source, so the counts hold either way.
>
> **Cost**: < $0.50 for the session (a second B2ts_v2 VM is created in
> Step 2; route tables and UDRs are free). Quota note: the second VM lands
> `standardBsv2Family` at exactly 4 of the track's 4 vCPUs — a fresh
> subscription starts at 0 and needs `az quota update` first (see
> STRAYLIGHT-REFERENCE.md, *Azure conventions*).
> **Teardown when done**: `azure/scripts/az700.sh destroy hub-spoke`
> (Step 6). This lab **ends** the Labs 1–3 shared session — Lab 4 deploys
> its own `nat-gateway` topology.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Azure subscription + az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `azure/scripts/az700.sh deploy hub-spoke` run this session | provides the RG, vnet-spoke1/2, vm-spoke1 and its NIC |
| Azure spend this session: < $0.50 | two B2ts_v2 VMs (vm-spoke1 + the NVA built in Step 2; needs 4 Bsv2-family vCPUs of quota) |
| Teardown: `az700.sh destroy hub-spoke` (Step 6) | this lab closes out the Labs 1–3 shared deployment |
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

## Step 1 — Read the system routes Azure already wrote

`vm-spoke1` has never been given a route table, yet it can already reach the
internet and every address in its own VNet. Ask its NIC what the fabric is
actually using — the **effective route table** is the merged, post-conflict
view, and it is the exam's favorite troubleshooting artifact:

<!-- @verify host=lab step=default-internet-route expect=/^1$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 \
  --query "length(value[?source=='Default' && nextHopType=='Internet'])" -o tsv
# Expected: 1   (exactly one system route sends 0.0.0.0/0 to Internet)
```

Two vocabularies to lock in. First, every route has a **source**: system
routes Azure creates for you, user routes you write (UDRs), and routes
learned from a gateway via BGP. In effective-route output the source strings
are `Default` (system), `User`, and `VirtualNetworkGateway` (BGP-learned).
Second, every route has a **nextHopType** — the ones the exam tests:

- `VnetLocal` — stay inside the VNet, delivered directly
- `VNetPeering` — cross a peering (these appear with source `Default`,
  which is why this lab's filters are peering-proof)
- `Internet` — out Azure's edge
- `VirtualAppliance` — forward to a specific IP (an NVA)
- `VirtualNetworkGateway` — into a VPN/ExpressRoute tunnel
- `None` — drop the packet (a black-hole route)

Route selection: Azure matches on **longest prefix first**, always. Only
when two routes have the *same* prefix does source precedence break the tie:
**User > BGP > System**. A /24 system route beats a /16 UDR — precedence
never overrides prefix length. Exam questions love implying otherwise.

## Step 2 — Create the NVA

A network virtual appliance is just a VM that routes: commercial firewalls,
SD-WAN edges, and open-source routers all ship as marketplace VM images. A
stock Ubuntu B2ts_v2 is a perfectly good stand-in for the routing mechanics.
Drop it into spoke1's workload subnet with no public IP and no NSG — it
should be reachable only from inside the estate:

<!-- @verify host=lab step=create-nva expect=/VM running/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az vm create --resource-group $RG --name vm-nva1 --image Ubuntu2404 \
  --size Standard_B2ts_v2 --vnet-name vnet-spoke1 --subnet snet-workload \
  --public-ip-address "" --nsg "" --admin-username azureuser \
  --generate-ssh-keys --query powerState -o tsv
# Expected: VM running
```

## Step 3 — Enable IP forwarding on the NIC (fabric level)

By default the Azure fabric delivers a packet to a NIC only if the packet is
addressed *to* that NIC — anything else is dropped before the VM ever sees
it. An NVA's whole job is receiving traffic addressed to other machines, so
its NIC needs `enableIPForwarding` (note the API's capital `IP` — the
JMESPath query below is case-sensitive). `az vm create` named the NIC
`<vm-name>VMNic`, so:

<!-- @verify host=lab step=enable-ip-forwarding expect=/true/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network nic update --resource-group $RG --name vm-nva1VMNic \
  --ip-forwarding true --query enableIPForwarding -o tsv
# Expected: true
```

This is the **fabric-level** half, and it is a NIC property — not a VM
property, not an OS setting. A real appliance also needs the **OS-level**
half (`net.ipv4.ip_forward=1` on Linux), or the kernel will drop the
forwarded packets the fabric now delivers. Both halves are required; the
exam likes asking which one a broken NVA is missing. The OS half is out of
scope here because no traffic will actually transit the NVA in this lab —
we are building the routing plumbing, not the appliance.

## Step 4 — A route table and a UDR pointing at the NVA

UDRs live in a **route table**, a standalone resource you later associate
with subnets. Create an empty one:

<!-- @verify host=lab step=create-route-table expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network route-table create --resource-group $RG --name rt-spoke1 \
  --query provisioningState -o tsv
# Expected: Succeeded
```

Now the route itself: send anything for spoke2 (`10.102.0.0/24`) to the
NVA's private IP. Look the IP up rather than hardcoding it — Azure handed
the NVA the next free address in the subnet:

<!-- @verify host=lab step=create-udr expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
NVAIP=$(az vm list-ip-addresses --resource-group $RG --name vm-nva1 \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)
az network route-table route create --resource-group $RG \
  --route-table-name rt-spoke1 --name to-spoke2-via-nva \
  --address-prefix 10.102.0.0/24 --next-hop-type VirtualAppliance \
  --next-hop-ip-address $NVAIP --query provisioningState -o tsv
# Expected: Succeeded
```

`VirtualAppliance` is the **only** next-hop type that takes an IP address —
`--next-hop-ip-address` is required with it and rejected with every other
type. If an exam answer pairs a next-hop IP with `Internet`, `None`, or
`VirtualNetworkGateway`, it is wrong on syntax alone.

## Step 5 — Associate the table and watch the override land

A route table does nothing until it is associated with a subnet — the
association is a subnet property, one table per subnet, one table reusable
across many subnets. Attach `rt-spoke1` to spoke1's workload subnet:

<!-- @verify host=lab step=associate-route-table expect=/rt-spoke1/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network vnet subnet update --resource-group $RG --vnet-name vnet-spoke1 \
  --name snet-workload --route-table rt-spoke1 \
  --query routeTable.id -o tsv
# Expected: .../routeTables/rt-spoke1
```

Re-read the effective route table on `vm-spoke1`'s NIC — the same command as
Step 1, now filtered for what we just injected:

<!-- @verify host=lab step=effective-user-route expect=/^1$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 \
  --query "length(value[?source=='User' && nextHopType=='VirtualAppliance'])" -o tsv
# Expected: 1   (the UDR is live on every NIC in the subnet, no reboot needed)
```

If Lab 2's direct spoke-to-spoke peering is still standing from the same
sitting, the NIC now holds **two** routes for `10.102.0.0/24` — and the
Step 1 tie-break rule is visible live. Ask for both (unannotated; it only
applies when Lab 2 ran first):

```bash
RG=rg-straylight-az700-hub-spoke
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 --query \
  "value[?addressPrefix[0]=='10.102.0.0/24'].{src:source, state:state, hop:nextHopType}" -o table
# Src      State    Hop
# Default  Invalid  VNetPeering        <- equal prefix, System loses
# User     Active   VirtualAppliance   <- equal prefix, User wins
```

Two failure modes worth knowing before the exam asks. If the NVA is later
deallocated, the UDR stays but the effective route flips to state
`Invalid` — traffic to 10.102.0.0/24 black-holes while every `az` resource
still shows `Succeeded`. And the classic scenario: a `0.0.0.0/0` UDR
pointing at a firewall NVA (forced tunneling) overrides the system internet
route for the **whole subnet** — every VM in it silently loses direct
internet access, including paths PaaS agents and extensions depend on. "We
added a default route to the firewall and now nothing can download updates"
is a stock AZ-700 question; the answer is always in the effective route
table.

## Step 6 — Teardown

This step ends the Labs 1–3 shared session. Lab 4 (Virtual Network NAT)
deploys its own `nat-gateway` topology fresh, so there is nothing to
preserve here:

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy hub-spoke
# Expected: "delete submitted for rg-straylight-az700-hub-spoke (async)"
```

The resource group is the state: the NVA, the route table, the UDR, and the
subnet association all die with it. Confirm later with
`azure/scripts/az700.sh list` or `az group list --tag track=az700 -o table`.

## What you proved

- Every NIC gets a working system route table with no configuration:
  `Default`-source routes for VnetLocal, Internet, and (when peered)
  VNetPeering next hops.
- Route selection is longest-prefix-match first; source precedence
  (User > BGP > System) only breaks ties at equal prefix length.
- An NVA needs fabric-level `enableIPForwarding` on its NIC *and* OS-level
  forwarding — the NIC property alone only makes the fabric deliver.
- `VirtualAppliance` is the only next-hop type that carries an IP, and a
  UDR takes effect the moment its route table is associated with the
  subnet — visible immediately as a `User`-source effective route.
- A `0.0.0.0/0` UDR to a firewall silently removes direct internet for the
  entire subnet — the effective route table is where that gets diagnosed.
