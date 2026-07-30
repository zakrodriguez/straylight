# Quiz — AZ-700 Hybrid Lab 3: BGP over the VPN

**Lab:** [`az700-hybrid-3-bgp-over-vpn-walkthrough.md`](../labs/az700-hybrid-3-bgp-over-vpn-walkthrough.md)
**Format:** 10 questions on dynamic routing, ASNs, APIPA peering, and
learned routes.
**Suggested time:** 10–15 minutes.

---

**Q1.** What does BGP replace on a S2S VPN, and name two capabilities that
require BGP.

(short answer)

---

**Q2.** What is the Azure VPN gateway's default ASN? What ASN range is
reserved and off-limits for your on-prem side?

(short answer)

---

**Q3.** What address does the on-prem BGP speaker peer with on the Azure
gateway by default, and when does the APIPA (169.254.x.x) peer apply
instead?

(short answer)

---

**Q4.** strongSwan is running the tunnel. Does it speak BGP? What runs the
BGP session on the on-prem side?

(short answer)

---

**Q5.** The BGP session won't establish over the tunnel. The neighbor is a
`169.254.x.x` address. What FRR option is usually required, and why?

(short answer)

---

**Q6.** Which two things must be set on the Azure side to enable BGP for
this connection?

(short answer)

---

**Q7.** After BGP is up, how do you read the routes Azure learned from
on-prem, and the routes on-prem learned from Azure?

(short answer)

---

**Q8.** With BGP running, you add a new spoke VNet on the Azure side. What
must you change on the on-prem LNG to route to it?

(short answer)

---

**Q9.** Why must the on-prem ASN differ from `65515`, and what range should
it come from?

(short answer)

---

**Q10.** BGP peers over the tunnel. What transport does the BGP session
itself use, and why does the tunnel have to be up first?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** BGP replaces the **static LNG address space** (hand-maintained
routes) with **dynamic route exchange**. It is required for active-active
gateways, multi-site failover, and ExpressRoute/VPN coexistence (any two).

**Q2.** Default gateway ASN is **65515**. The reserved Azure range is
**65515–65520** — don't use those for on-prem.

**Q3.** By default, the gateway's **GatewaySubnet IP**
(`defaultBgpIpAddresses`, e.g. 10.100.0.30). **APIPA (169.254.x.x)**
addresses (`customBgpIpAddresses`) are an opt-in — required for
active-active gateways and on-prem devices that mandate APIPA, not the
single-gateway default. (The question's framing is the active-active case;
know both.)

**Q4.** No — strongSwan is data plane only. A **BGP daemon (FRR)** runs the
session beside it on vpn1.

**Q5.** `ebgp-multihop` (usually 2) — the APIPA peer isn't directly
on-link across the tunnel, so single-hop eBGP won't reach it. (A static
route to the APIPA address via the tunnel is the alternative.)

**Q6.** On the **LNG**: an ASN and a BGP peering address for the on-prem
side. On the **connection**: `enableBgp: true`.

**Q7.** Azure: `az network vnet-gateway list-learned-routes` on the
gateway. On-prem: `show ip route bgp` (via `vtysh`) on vpn1.

**Q8.** **Nothing** — that's the point of BGP. The new spoke's prefix is
advertised and learned automatically; static LNG editing is exactly what
BGP eliminates.

**Q9.** BGP requires distinct ASNs on each side to form an eBGP session;
`65515` is Azure's. Use a **private ASN (64512–65534)**, avoiding the
reserved 65515–65520.

**Q10.** BGP runs over **TCP/179** *inside* the IPsec tunnel (its packets
match the traffic selectors and are encrypted). The tunnel must be up first
because it is the transport for the BGP session.

</details>
