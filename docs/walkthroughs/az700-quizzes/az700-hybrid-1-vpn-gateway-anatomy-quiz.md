# Quiz — AZ-700 Hybrid Lab 1: VPN Gateway Anatomy

**Lab:** [`az700-hybrid-1-vpn-gateway-anatomy-walkthrough.md`](../labs/az700-hybrid-1-vpn-gateway-anatomy-walkthrough.md)
**Format:** 10 questions on the four S2S resources, gateway types/SKUs, and
the connection policy.
**Suggested time:** 10–15 minutes.

---

**Q1.** A site-to-site VPN is four Azure resources. Name them and say what
each is responsible for.

(short answer)

---

**Q2.** `vpnType: RouteBased` versus policy-based: which IKE version does
each use, and name two capabilities that require route-based.

(short answer)

---

**Q3.** What does the `AZ` suffix on `VpnGw1AZ` mean, and what constraint
does it place on the gateway's public IP?

(short answer)

---

**Q4.** The local network gateway is named "gateway" but isn't a running
resource. What is it, and what are the two values it must get right?

(short answer)

---

**Q5.** Predict the output shape:

```bash
az network vpn-connection show -g $RG -n cn-straylight-s2s \
  --query "{status:connectionStatus, ingress:ingressBytesTransferred}" -o json
```

run right after the gateway deploys but before any on-prem peer initiates.

(predict + reason)

---

**Q6.** The connection carries an explicit `ipsecPolicies` entry instead of
using Azure's default policy. Why — what real failure does pinning a policy
prevent?

(short answer)

---

**Q7.** What is `65515` in `bgpSettings.asn`, and can you change it to any
value?

(short answer)

---

**Q8.** Basic SKU: name three things it cannot do that a `VpnGwNAZ` SKU can.

(short answer)

---

**Q9.** The `gatewayIpAddress` on the LNG is stale (your router's public IP
changed). What symptom does this produce, and what command fixes it?

(short answer)

---

**Q10.** Why is the on-prem address space modelled as `192.168.56.0/21`
rather than the specific `/24` a given lab actually uses?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** (1) **Virtual network gateway** — the Azure VPN endpoint, in the
hub's `GatewaySubnet`. (2) **Public IP** — the address the on-prem peer
dials. (3) **Local network gateway** — Azure's description of the on-prem
site (its public IP + address space). (4) **Connection** — binds the two
gateways with a PSK, protocol (IKEv2), and IPsec policy.

**Q2.** Route-based uses **IKEv2**; policy-based uses **IKEv1**.
Route-based is required for BGP, point-to-site, active-active, and
ExpressRoute/VPN coexistence (any two suffice). Policy-based is legacy,
single-connection, on-prem-selector-bound.

**Q3.** `AZ` = **zone-redundant** — the gateway spans availability zones.
It requires a **zone-redundant Standard** public IP with **static**
allocation.

**Q4.** A **description of the remote (on-prem) site**, not a running
thing: the on-prem **public IP** (`gatewayIpAddress`) to reach and the
on-prem **address space** (`localNetworkAddressSpace`) to route toward.
Both wrong-able independently; either error breaks connectivity.

**Q5.** `connectionStatus: NotConnected`, `0` bytes. Correct: the Azure
gateway is the **responder** and no on-prem initiator has dialed in yet.

**Q6.** Azure's **default IPsec/IKE policy set did not negotiate** with the
on-prem strongSwan on this SKU — the initiator got `NO_PROPOSAL_CHOSEN` at
IKE_SA_INIT for every combination in Azure's documented default list.
Pinning one explicit policy (matched on both ends) makes negotiation
deterministic.

**Q7.** The gateway's **BGP ASN** (autonomous system number). You may
override it, but **not** to a reserved Azure ASN (65515–65520). It only
matters once BGP is enabled.

**Q8.** No BGP, no active-active, no zone redundancy (also: fewer tunnels,
lower throughput, no P2S IKEv2/OpenVPN in some cases). Never for new
designs.

**Q9.** The tunnel **fails to come up / no traffic** — Azure sends IKE to
the wrong on-prem address. Fix: `az700.sh update-onprem-ip hybrid-vpn`
(updates the LNG `gatewayIpAddress` to the current public IP), then
re-provision vpn1.

**Q10.** `192.168.56.0/21` is the whole host-only supernet — it covers
every `/24` the dynamic-octet allocator can assign, so the on-prem
**traffic selector never changes per build**. A specific `/24` would break
the tunnel whenever the lab landed on a different octet.

</details>
