# AZ-700 Hybrid Lab 1 — VPN Gateway Anatomy

A site-to-site VPN is not one resource — it is four, and the exam tests
whether you know which does what. This lab deploys the Azure side of the
hybrid connection and dissects it: the **virtual network gateway** (the
Azure endpoint), its **public IP**, the **local network gateway** (Azure's
model of your on-prem site), and the **connection** that binds them with an
IPsec policy. No tunnel comes up here — that is Lab 2. Here you learn the
pieces, why each is shaped the way it is, and where the settings that make
or break negotiation live.

Pairs with MS Learn: *Design and implement hybrid connectivity* — VPN
gateway types, SKUs, and the connection model (AZ-700 learning path).

> **Before you start**: run the CGNAT precheck once (see
> `azure/docs/costs.md`) — a real public IP on your router is the
> prerequisite for the whole module. Then deploy the Azure side. The
> gateway takes **20–45 minutes** to provision, so start it and gate on it:
>
> ```bash
> az account show --query id -o tsv            # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy hybrid-vpn --no-wait
> azure/scripts/az700.sh watch hybrid-vpn      # polls until Succeeded (~21 min typical)
> azure/scripts/az700.sh deploy hybrid-vpn     # idempotent re-run: records the gateway public IP
> ```
>
> Labs 1–3 share this one gateway — run them back-to-back in a single
> sitting and tear down once at the end.
>
> **Cost**: the gateway meters at **~$0.36/hr from creation**, provisioning
> window included. A full module sitting is ~$0.55.
> **Teardown when done**: `azure/scripts/az700.sh destroy hybrid-vpn`
> (Lab 3, Step 6). Never leave a gateway up overnight (~$9/day).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Azure subscription + az CLI ≥ 2.60, logged in | every step here is `az` from the host |
| `azure/scripts/az700.sh deploy hybrid-vpn` provisioned (`watch` shows Succeeded) | the gateway and its four sibling resources must exist to inspect |
| CGNAT precheck passed | the tunnel in Lab 2 needs a routable on-prem public IP |
| Verification: VERIFIABLE (walkverify golden, live-capture) | pure az CLI projections; golden captured against a standing gateway |

## Setup (one-time, idempotent)

Confirm the deployment finished:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded   (else: az700.sh deploy hybrid-vpn --no-wait; watch hybrid-vpn)
```

## Step 1 — The virtual network gateway

The **virtual network gateway** is Azure's VPN endpoint. It lives in the
hub VNet's `GatewaySubnet` (a reserved subnet name — Lab 1 of the vnet
module) and it is the single most consequential cost and capability choice
in a hybrid design. Read its shape:

<!-- @verify host=lab step=gateway-shape expect=/RouteBased/ expect=/VpnGw1AZ/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vnet-gateway show --resource-group $RG --name vpngw-hub \
  --query "{type:gatewayType, vpnType:vpnType, sku:sku.name, gen:vpnGatewayGeneration, asn:bgpSettings.asn, active:activeActive}" -o json
# Expected: gatewayType Vpn, vpnType RouteBased, sku VpnGw1AZ,
#           vpnGatewayGeneration Generation1, asn 65515, activeActive false
```

Three choices to lock in for the exam:

- **`vpnType: RouteBased`** — route-based (dynamic) gateways use IKEv2 and
  traffic selectors of `0.0.0.0/0`-style *any-to-any*, and are required for
  BGP, point-to-site, and coexistence. Policy-based (static) gateways use
  IKEv1 and are legacy, single-connection, on-prem-selector-bound. Choose
  route-based unless a specific legacy peer forces otherwise.
- **`sku: VpnGw1AZ`** — the SKU sets aggregate throughput (~650 Mbps for
  Gw1), tunnel count, and BGP support. The `AZ` suffix is
  **zone-redundant** — the gateway spans availability zones, which is why
  its public IP must be a zone-redundant Standard IP (Step 2). Basic SKU
  has no BGP, no active-active, no zone redundancy — never for new designs.
- **`asn: 65515`** — the gateway's BGP autonomous-system number.
  `65515` is Azure's default for the gateway side; you can override it, but
  not to a reserved Azure ASN. It matters only once BGP is on (Lab 3).

## Step 2 — The gateway's public IP

The gateway terminates the tunnel on a public IP. For an AZ (zone-redundant)
SKU it must be a **zone-redundant Standard** public IP with **static**
allocation — the tunnel's remote address on your on-prem side, so it must
not change under the gateway.

<!-- @verify host=lab step=gateway-pip expect=/Static/ expect=/Standard/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network public-ip show --resource-group $RG --name pip-vpngw \
  --query "{alloc:publicIPAllocationMethod, sku:sku.name, zones:zones, ip:ipAddress}" -o json
# Expected: publicIPAllocationMethod Static, sku Standard, zones ["1","2","3"]
#           ip: the gateway's public address (what your on-prem peer dials)
```

That `ip` is the address `vpn1` dials in Lab 2. It was recorded into
`~/.straylight/az700/hybrid-vpn.env` by `post-deploy.sh` — the on-prem side
reads it from there, never hardcoded.

## Step 3 — The local network gateway (your on-prem site, as Azure sees it)

The **local network gateway** (LNG) is Azure's model of the *remote* site —
despite "gateway" in the name, it is not a running resource, just a
description: the on-prem public IP to reach, and the on-prem address space
to route toward. Get them wrong and the tunnel builds but no traffic flows.

<!-- @verify host=lab step=lng-shape expect=/192\.168\.56\.0/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network local-gateway show --resource-group $RG --name lgw-straylight \
  --query "{onpremIp:gatewayIpAddress, space:localNetworkAddressSpace.addressPrefixes}" -o json
# Expected: gatewayIpAddress = your router's public IP (captured at deploy)
#           localNetworkAddressSpace = ["192.168.56.0/21"]
```

`192.168.56.0/21` is the lab's whole host-only supernet — it covers every
`/24` the dynamic-octet allocator can hand a lab, so the on-prem selector
never changes per build (a locked convention;
STRAYLIGHT-REFERENCE.md, *Azure conventions*). If your router's public IP
has changed since deploy, `az700.sh update-onprem-ip hybrid-vpn` refreshes
the `gatewayIpAddress` — a stale LNG IP is the single most common S2S
"tunnel won't come up" cause.

## Step 4 — The connection and its pinned IPsec policy

The **connection** binds the two gateways with a pre-shared key, a protocol,
and a crypto policy. This is where negotiation succeeds or fails.

<!-- @verify host=lab step=connection-shape expect=/IPsec/ expect=/DHGroup14/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vpn-connection show --resource-group $RG --name cn-straylight-s2s \
  --query "{type:connectionType, proto:connectionProtocol, bgp:enableBgp, policy:ipsecPolicies[0].{ike:ikeEncryption, ikeInt:ikeIntegrity, dh:dhGroup, esp:ipsecEncryption, pfs:pfsGroup}}" -o json
# Expected: connectionType IPsec, connectionProtocol IKEv2, enableBgp false,
#           policy: AES256 / SHA256 / DHGroup14 / AES256 / None
```

That explicit `ipsecPolicies` entry is not decoration — it is the fix for a
real failure. Azure's **default** policy set did not negotiate with
strongSwan on this SKU: the initiator got `NO_PROPOSAL_CHOSEN` at
IKE_SA_INIT for every combination in Azure's *documented* default list,
including the AES256/SHA256/DHGroup14 combo shown here. Pinning one explicit
policy on the connection — matched exactly by the on-prem side's
proposals — makes negotiation deterministic. The exam lesson: when a
route-based S2S tunnel fails at IKE with a proposal error and both ends
"look right", stop trusting the default policy and pin an explicit,
identical IPsec/IKE policy on both peers.

`enableBgp: false` is the current state — Lab 3 turns it on.

## Step 5 — Read the connection's live status (still down)

The connection object reports a status even before any tunnel exists.

<!-- @verify host=lab step=connection-status expect=/NotConnected/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vpn-connection show --resource-group $RG --name cn-straylight-s2s \
  --query "{status:connectionStatus, ingress:ingressBytesTransferred, egress:egressBytesTransferred}" -o json
# Expected: connectionStatus NotConnected, 0 bytes each way
#           (no on-prem peer has dialed in yet — that is Lab 2)
```

`NotConnected` with zero bytes is correct here: the Azure side is a patient
responder waiting for `vpn1` to initiate. In Lab 2 you bring up the on-prem
initiator and watch this flip to `Connected`.

## What you proved

- A S2S VPN is four resources: the **virtual network gateway** (Azure
  endpoint, in `GatewaySubnet`), its **static zone-redundant public IP**,
  the **local network gateway** (a description of the on-prem site — public
  IP + address space, not a running thing), and the **connection** (PSK +
  IKEv2 + IPsec policy) that binds them.
- Route-based + an AZ SKU are the defaults that unlock BGP, P2S, and zone
  redundancy; policy-based and Basic are legacy dead-ends.
- The connection's **explicit IPsec policy** exists because Azure's default
  policy would not negotiate — the canonical "pin an identical policy on
  both ends" S2S troubleshooting move.
- The connection sits `NotConnected` until an on-prem peer initiates — the
  Azure gateway is always the responder in this design.
