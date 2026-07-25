# Quiz — AZ-700 VNet Lab 2: Hub-and-Spoke Peering and Non-Transitivity

**Lab:** `az700-vnet-2-peering-hub-spoke-walkthrough.md`
**Format:** 10 questions on the `peeringState` lifecycle,
unidirectional peering resources, effective-route evidence,
non-transitivity and its three fixes, and the gateway-transit
flag pair.
**Suggested time:** 10–15 minutes.

---

**Q1.** A "peering" between `vnet-hub` and `vnet-spoke1`: how many
Azure resources is it, where does each one live, and when does
traffic actually flow?

(short answer)

---

**Q2.** Only the hub's half exists. Predict the output, and state
whether traffic flows:

```bash
az network vnet peering create --resource-group $RG --name hub-to-spoke1 \
  --vnet-name vnet-hub --remote-vnet vnet-spoke1 \
  --allow-vnet-access --allow-forwarded-traffic -o none
az network vnet peering show --resource-group $RG --vnet-name vnet-hub \
  --name hub-to-spoke1 --query peeringState -o tsv
```

(predict the output)

---

**Q3.** The hub's `hub-to-spoke1` peering later reports
`Connected` without ever being touched again. What single action
caused the state change?

(short answer)

---

**Q4.** Match each peering flag to its effect:

| Flag | Effect |
|---|---|
| `allowVirtualNetworkAccess` | __________ |
| `allowForwardedTraffic` | __________ |
| `allowGatewayTransit` | __________ |
| `useRemoteGateways` | __________ |

(choices: permits traffic between the peered VNets at all;
accepts packets the remote VNet forwarded rather than originated;
offers this VNet's VPN/ExpressRoute gateway to the remote VNet;
consumes the remote VNet's gateway for this VNet's traffic)

---

**Q5.** hub↔spoke1 and hub↔spoke2 are both `Connected`; no
spoke-to-spoke peering exists. Predict the output:

```bash
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 --query \
  "length(value[?nextHopType=='VNetPeering' && addressPrefix[0]=='10.102.0.0/24'])" \
  -o tsv
```

(predict the output + reason)

---

**Q6.** Before any peering exists, name the three kinds of system
routes every NIC starts with (prefix → next hop), and say which
one handles a packet from `vm-spoke1` to a hub address in
`10.100.0.0/22` — and what happens to that packet.

(short answer)

---

**Q7.** Name all three ways to get spoke-to-spoke traffic, and
give the number of peerings a full mesh of 6 spokes requires.

(short answer)

---

**Q8.** Both spoke peerings were created with
`--allow-forwarded-traffic`, so a colleague expects spoke1 to
reach spoke2 through the hub. Explain the two reasons it still
cannot.

(short answer)

---

**Q9.** Gateway transit: which flag goes on which side of the
hub–spoke peering, what do the spokes gain, and what is the rule
about the two flags on the same side of a peering?

(short answer)

---

**Q10.** The lab ends with hub↔spoke1, hub↔spoke2, and
spoke1↔spoke2 all `Connected`. How many peering resources exist
in total? Name them.

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** Two unidirectional resources, each living inside the VNet
it points *from* (`hub-to-spoke1` in `vnet-hub`, `spoke1-to-hub`
in `vnet-spoke1`). Traffic flows only once both exist and each
reports `peeringState` = `Connected`.

**Q2.** `Initiated`. No traffic flows — `Initiated` is the
waiting state: this side is configured but the reverse resource
does not exist yet. The lifecycle is `Initiated` → `Connected`.

**Q3.** The matching peering (`spoke1-to-hub`) was created inside
`vnet-spoke1`. The lifecycle advances only when the reverse
resource appears in the remote VNet — a topology stuck at
`Initiated` is always fixed by creating the missing direction.

**Q4.**
- `allowVirtualNetworkAccess` → permits traffic between the
  peered VNets at all
- `allowForwardedTraffic` → accepts packets the remote VNet
  forwarded rather than originated
- `allowGatewayTransit` → offers this VNet's VPN/ExpressRoute
  gateway to the remote VNet
- `useRemoteGateways` → consumes the remote VNet's gateway for
  this VNet's traffic

**Q5.** `0`. Peering is non-transitive: a peering programs routes
only for the two VNets it directly joins, so spoke1 learned the
hub's `10.100.0.0/22` and nothing beyond it. `10.102.0.0/24`
still falls through to the RFC 1918 → `None` route.

**Q6.** (1) The VNet's own prefix (`10.101.0.0/24`) → next hop
**VirtualNetwork**; (2) `0.0.0.0/0` → next hop **Internet**;
(3) the RFC 1918 ranges → next hop **None**. A packet to
`10.100.x.x` matches the RFC 1918 → None route and is silently
dropped.

**Q7.** (1) Direct spoke-to-spoke peering — simplest, but a full
mesh needs n(n−1)/2 peerings; (2) an NVA in the hub plus UDRs in
each spoke pointing spoke prefixes at it; (3) a hub gateway with
gateway transit (`allowGatewayTransit` / `useRemoteGateways`).
For 6 spokes the mesh costs 6×5/2 = 15 peerings.

**Q8.** First, `allowForwardedTraffic` only *permits* forwarded
packets to arrive — it creates no routes, so spoke1 has no route
for spoke2's prefix. Second, nothing in the hub forwards between
spokes: there is no router VM and no gateway, so a two-hop path
through the hub does not exist.

**Q9.** `allowGatewayTransit` on the hub's side offers the hub's
VPN or ExpressRoute gateway; `useRemoteGateways` on the spoke's
side consumes it. Spokes then reach on-premises through the hub
without gateways of their own. The two flags can never both be
true on the same side of a peering — one side offers a gateway,
the other uses it.

**Q10.** Six: `hub-to-spoke1`, `spoke1-to-hub`, `hub-to-spoke2`,
`spoke2-to-hub`, `spoke1-to-spoke2`, `spoke2-to-spoke1` — two
unidirectional resources per connected pair.

</details>
