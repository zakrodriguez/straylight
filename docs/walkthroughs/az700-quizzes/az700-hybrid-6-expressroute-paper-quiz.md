# Quiz — AZ-700 Hybrid Lab 6: ExpressRoute (Paper)

**Lab:** [`az700-hybrid-6-expressroute-paper-walkthrough.md`](../labs/az700-hybrid-6-expressroute-paper-walkthrough.md)
**Format:** 10 questions on circuits, peering, SKUs, and coexistence.
**Suggested time:** 10–15 minutes.

---

**Q1.** What is the fundamental difference between ExpressRoute and a VPN
gateway connection?

(short answer)

---

**Q2.** An ExpressRoute circuit is provisioned in two halves. What are they,
and what links your side to the provider's?

(short answer)

---

**Q3.** Name the two current peering types and what each reaches. What is the
status of public peering?

(short answer)

---

**Q4.** To reach your VNets over private peering, what gateway type must the
VNet have?

(short answer)

---

**Q5.** Name the three circuit SKUs and the one-line distinction of each.

(short answer)

---

**Q6.** Metered vs Unlimited billing — when would you choose each?

(short answer)

---

**Q7.** What does Global Reach do?

(short answer)

---

**Q8.** What is ExpressRoute Direct?

(short answer)

---

**Q9.** What does FastPath change — the control plane or the data path?

(short answer)

---

**Q10.** Three gotchas: (a) what SLA config does a single circuit *not* meet,
(b) is ExpressRoute encrypted by default, (c) in ER+VPN coexistence, what
arbitrates the preferred path?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** ExpressRoute is a **private connection** through a provider to the
Microsoft edge — **no IPsec, no tunnel, not over the public internet**. A VPN
gateway rides the public internet with IPsec encryption.

**Q2.** You **create the circuit** in Azure (it issues a **service key**); the
**provider lights their side** using that key. The circuit stays
`Provisioned: false` until the provider completes their half.

**Q3.** **Private peering** reaches your **VNets** (private IPs);
**Microsoft peering** reaches **Microsoft public services**. **Public peering
is retired** (folded into Microsoft peering).

**Q4.** An **ExpressRoute-type gateway** (`gatewayType: ExpressRoute`), in a
`GatewaySubnet` — distinct from the VPN gateway type.

**Q5.** **Local** (only the circuit's metro regions, no egress charge),
**Standard** (any region in the same geopolitical area), **Premium**
(**global** reach + higher route/VNet limits).

**Q6.** **Metered** = port fee + per-GB egress — good for **low/bursty**
egress. **Unlimited** = higher flat fee, no per-GB — good for **high, steady**
egress.

**Q7.** **Global Reach** links **two ExpressRoute circuits** so your **on-prem
sites reach each other over the Microsoft backbone** (branch-to-branch),
bypassing your own WAN.

**Q8.** Provisioning **your own dual 10/100 Gbps ports directly onto
Microsoft's routers** (no provider in the middle); you carve circuits out of
that port pair. For massive/sovereign/MACsec-encrypted connectivity.

**Q9.** The **data path** — traffic goes straight from the ER gateway to the
VM, bypassing the gateway's routing hop. The control plane (BGP) is unchanged.

**Q10.** (a) A **single circuit** does not meet the **99.95% SLA** — that
needs **two circuits / redundant peering locations**. (b) **No**, ER is **not
encrypted by default**. (c) **BGP** arbitrates (ER primary preferred; VPN as
encrypted backup).

</details>
