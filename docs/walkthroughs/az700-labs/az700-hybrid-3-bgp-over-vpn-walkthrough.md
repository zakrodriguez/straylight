# AZ-700 Hybrid Lab 3 — BGP over the VPN

The tunnel from Lab 2 carries exactly the prefixes named in the local
network gateway — a **static** route plan. Change the on-prem address space
and you must edit the LNG by hand; add a spoke on the Azure side and every
on-prem site needs the new prefix. BGP replaces that hand-editing with
**dynamic route exchange**: each side advertises its prefixes and learns
the other's automatically, and — the reason it matters for the exam — BGP
is the prerequisite for active-active gateways, multi-site failover, and
ExpressRoute + VPN coexistence. This lab reads the Azure gateway's BGP
identity, then documents enabling BGP end to end and reading the routes it
learns.

Pairs with MS Learn: *Design and implement hybrid connectivity* — configure
BGP for VPN gateways (AZ-700 learning path).

> **Before you start**: Lab 2's tunnel must be established. BGP peers over
> that tunnel, so it is the transport for the BGP session. This lab enables
> BGP on the Azure connection, provisions an FRR speaker on vpn1 (the
> `strongswan_azure` role does this when `BGP_PEER` is in the env), and
> reads the routes each side learns. Step 6 tears the whole module down.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Lab 2's tunnel established | BGP peers over the IPsec tunnel (transport for the TCP/179 session) |
| Gateway BGP enabled (it is — ASN 65515 by default) | the Azure side already has a BGP identity to read in Step 1 |
| `strongswan_azure` role (FRR on vpn1 when `BGP_PEER` set) | provisions the on-prem BGP speaker |
| Verification: VERIFIABLE (walkverify golden, live-capture) | az reads + `vtysh` on vpn1, against a standing BGP session |

## Step 1 — The Azure gateway's BGP identity

Even with the connection's BGP disabled, the gateway carries a BGP identity:
an ASN and a **BGP peering address** on the gateway. Read it:

<!-- @verify host=lab step=gateway-bgp-identity expect=/65515/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vnet-gateway show --resource-group $RG --name vpngw-hub \
  --query "{asn:bgpSettings.asn, peerWeight:bgpSettings.peerWeight, bgpPeerIps:bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses}" -o json
# Expected: asn 65515, and a default BGP peering IP inside the
#           GatewaySubnet (e.g. 10.100.0.30)
```

Two exam facts live here. **ASN 65515** is Azure's default gateway ASN —
you may override it, but not to a reserved Azure ASN (65515–65520). And the
default **BGP peering address is an IP inside the GatewaySubnet**
(`defaultBgpIpAddresses`, e.g. `10.100.0.30`) — the on-prem BGP speaker
peers with *that* address over the tunnel by default. Azure can
*additionally* assign **APIPA (169.254.x.x) BGP addresses**
(`customBgpIpAddresses`) — required for active-active gateways and for
on-prem devices that mandate APIPA peers, but not the default for a single
active-passive gateway. The exam distinction: `defaultBgpIpAddresses` =
GatewaySubnet IP (the usual peer); `customBgpIpAddresses` = APIPA (opt-in,
active-active).

## Step 2 — Enable BGP on the Azure side and write the BGP env

BGP is off on the connection by default. The Azure half is two updates:
give the LNG the on-prem ASN and vpn1's tunnel-facing address, and flip
`enableBgp` on the connection. Then record the gateway's default BGP peer
and the on-prem ASN into the env file the `strongswan_azure` role reads.
On the host:

```bash
RG=rg-straylight-az700-hybrid-vpn
ENV=~/.straylight/az700/hybrid-vpn.env
# vpn1's host-only IP (octet .45); it varies per lab, so discover it.
VPN1_IP=$(cd vagrant && VAGRANT_DOTFILE_PATH=.vagrant-az700-hybrid LAB_PROFILE=az700-hybrid \
  vagrant ssh vpn1 -c "ip -4 -o addr show | grep 192.168 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | tr -d '\r')
# The gateway's default BGP peer (an in-VNet address, e.g. 10.100.0.30).
GW_BGP=$(az network vnet-gateway show -g $RG -n vpngw-hub \
  --query "bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]" -o tsv)

az network local-gateway update -g $RG -n lgw-straylight \
  --asn 65050 --bgp-peering-address "$VPN1_IP" -o none
az network vpn-connection update -g $RG -n cn-straylight-s2s \
  --set enableBgp=true --query enableBgp -o tsv

# Persist BGP params so the role configures FRR on the next provision.
umask 177
grep -v '^BGP_PEER=\|^ONPREM_ASN=' "$ENV" > "$ENV.tmp" 2>/dev/null || true; mv "$ENV.tmp" "$ENV"
{ echo "BGP_PEER=$GW_BGP"; echo "ONPREM_ASN=65050"; } >> "$ENV"; chmod 600 "$ENV"
# enableBgp becomes true (the az updates emit async-poll notices; harmless)
```

The on-prem ASN (`65050`) is a private ASN (64512–65534) distinct from
Azure's `65515`. The `--bgp-peering-address` is where Azure expects the
on-prem BGP speaker — vpn1's tunnel-facing address, which must fall inside
the LNG address space (`192.168.56.0/21`).

## Step 3 — Provision FRR on vpn1

strongSwan carries the data plane; it does not speak BGP. Re-provision vpn1:
with `BGP_PEER` now in the env, the `strongswan_azure` role installs FRR,
enables `bgpd`, and renders `/etc/frr/frr.conf` — a single eBGP neighbor
(the gateway peer), `ebgp-multihop 2` (the peer is not on-link across the
tunnel — the classic "BGP won't establish over VPN" gotcha), advertising
the on-prem supernet. On the host:

```bash
cd vagrant && LAB_PROFILE=az700-hybrid VAGRANT_DOTFILE_PATH=.vagrant-az700-hybrid \
  vagrant provision vpn1
```

Then confirm FRR came up with the neighbor configured. On `vpn1`:

<!-- @verify host=lab step=frr-configured expect=/remote-as 65515/ rc=0 -->
```bash
cd vagrant && VAGRANT_DOTFILE_PATH=.vagrant-az700-hybrid LAB_PROFILE=az700-hybrid \
  vagrant ssh vpn1 -c "sudo vtysh -c 'show running-config' | grep -E 'router bgp|remote-as|network 192'" 2>/dev/null
# Expected: router bgp 65050 / neighbor <gw> remote-as 65515 / network 192.168.56.0/21
```

## Step 4 — Confirm the BGP session

Once both ends speak BGP, the session establishes over the tunnel. On
`vpn1`:

<!-- @verify host=lab step=bgp-established expect=/65515/ rc=0 -->
```bash
cd vagrant && VAGRANT_DOTFILE_PATH=.vagrant-az700-hybrid LAB_PROFILE=az700-hybrid \
  vagrant ssh vpn1 -c "sudo vtysh -c 'show bgp summary' | grep -A2 Neighbor" 2>/dev/null
# Expected: the gateway neighbor line (AS 65515), State/PfxRcd showing an
#           established session (a number, not Active/Connect/Idle)
```

## Step 5 — Read the routes each side learned

The payoff: Azure learns the on-prem prefix and the on-prem side learns the
Azure prefixes, with no static LNG editing. On `vpn1`:

<!-- @verify host=lab step=learned-routes expect=/10\.100/ rc=0 -->
```bash
cd vagrant && VAGRANT_DOTFILE_PATH=.vagrant-az700-hybrid LAB_PROFILE=az700-hybrid \
  vagrant ssh vpn1 -c "sudo vtysh -c 'show bgp ipv4 unicast' | grep -E '10.100|192.168.56'" 2>/dev/null
# Expected:
#   10.100.0.0/22   10.100.0.30 ... 65515 i   <- learned from Azure via BGP
#   192.168.56.0/21 0.0.0.0 ...       32768 i   <- originated toward Azure
```

Azure learned the on-prem prefix in return — on the host,
`az network vnet-gateway list-learned-routes -g $RG -n vpngw-hub
--query "value[?asPath=='65050']" -o table` shows `192.168.56.0/21` with
AS-path `65050`. Change a prefix on either side and it propagates
automatically — the whole reason BGP exists on the wire.

> **Why the BGP table, not `show ip route bgp`?** The learned Azure prefix
> has the peer (`10.100.0.30`) as its next hop, which is not on-link across
> a *policy-based* strongSwan tunnel (traffic selectors, no routing
> interface), so FRR keeps the route in its BGP table but does not install
> it in the kernel RIB. That is fine for this lab — the control-plane
> exchange is the lesson, and the tunnel's static selectors
> (`10.100.0.0/14`) already carry the data plane. Installing BGP-learned
> routes into the kernel would need a route-based (VTI/XFRM-interface)
> tunnel, which the P3b active-active lab builds on.

## Step 6 — Teardown (closes the module)

This step ends the hybrid session. The gateway is the track's most
expensive resource — do not skip it.

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy hybrid-vpn
# Expected: "delete submitted for rg-straylight-az700-hybrid-vpn (async)"
```

Then remove the on-prem VMs (they cost nothing running, but the module is
done):

```bash
cd vagrant && LAB_PROFILE=az700-hybrid ./nuke.sh --yes-delete-without-prompt
```

The gateway, its public IP, the LNG, the connection, and `vm-hub1` all die
with the resource group; vpn1's tunnel becomes a dead peer and stops
retrying once nuked. Confirm the Azure side is gone with
`azure/scripts/az700.sh list`.

## What you proved

- A static LNG address space is hand-maintained; **BGP exchanges routes
  dynamically**, and it is the prerequisite for active-active gateways,
  multi-site failover, and ExpressRoute/VPN coexistence.
- The Azure gateway's default **ASN is 65515**, and BGP over VPN peers by
  default with the gateway's **GatewaySubnet address**
  (`defaultBgpIpAddresses`); **APIPA (169.254.x.x)** addresses
  (`customBgpIpAddresses`) are the active-active / opt-in case.
- The on-prem side uses a distinct private ASN, a BGP speaker (FRR) beside
  strongSwan, and usually `ebgp-multihop` to reach the APIPA peer.
- Learned routes replace static ones on both ends — read them with
  `az network vnet-gateway list-learned-routes` (Azure) and
  `show ip route bgp` (on-prem).
