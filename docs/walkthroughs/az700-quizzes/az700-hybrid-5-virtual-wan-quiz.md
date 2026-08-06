# Quiz — AZ-700 Hybrid Lab 5: Virtual WAN

**Lab:** [`az700-hybrid-5-virtual-wan-walkthrough.md`](../labs/az700-hybrid-5-virtual-wan-walkthrough.md)
**Format:** 10 questions on the vWAN model, hubs, and routing intent.
**Suggested time:** 10–15 minutes.

---

**Q1.** What does Virtual WAN manage for you that a hand-built hub-and-spoke
makes you manage yourself? Name two things.

(short answer)

---

**Q2.** Basic vs Standard virtual WAN: name two capabilities Standard has that
Basic does not.

(short answer)

---

**Q3.** What is a *secured virtual hub*, and what feature forces traffic
through the firewall without UDRs?

(short answer)

---

**Q4.** Two VNets are connected to the same virtual hub. What must you
configure for them to reach each other?

(short answer)

---

**Q5.** A virtual hub needs an address prefix. Do you subnet it yourself?

(short answer)

---

**Q6.** Where do the routes in a hub's `defaultRouteTable` come from?

(short answer)

---

**Q7.** Which vWAN type is required for hub-to-hub (inter-region) any-to-any
transit?

(short answer)

---

**Q8.** Name three things that can attach to a virtual hub.

(short answer)

---

**Q9.** Routing intent vs the vnet module's NVA-plus-UDR pattern — what is the
same, what is different?

(short answer)

---

**Q10.** You have twelve VNets across three regions plus several branch
offices, all needing any-to-any connectivity. Self-built hub-spoke or vWAN,
and why?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** vWAN manages the **hub router** (Microsoft-operated virtual hub) and
**automatic any-to-any transit** — no peering mesh, no hand-written transit
UDRs (either two count).

**Q2.** **Standard** adds hub-to-hub transit, ExpressRoute, P2S, and inter-hub
any-to-any; **Basic** is **S2S VPN only** (any two of those Standard-only
capabilities).

**Q3.** A hub with **Azure Firewall deployed into it**; **routing intent**
(send private and/or internet traffic to the firewall) forces inspection
across all flows **without any UDRs**.

**Q4.** **Nothing beyond the connections** — Standard vWAN gives **automatic
any-to-any**; both spoke prefixes appear in the hub route table automatically.

**Q5.** **No** — the hub is **Microsoft-managed**; you give it a dedicated
`/23` and never subnet it.

**Q6.** They are **learned automatically** from the hub's connections (VNet
connections, VPN/ER/P2S) — the managed router maintains the table; you write
no UDRs.

**Q7.** **Standard** virtual WAN.

**Q8.** Any three of: **VNet connections**, **S2S VPN** (VPN gateway),
**ExpressRoute** circuits, **P2S** (user VPN), Azure Firewall (secured hub).

**Q9.** **Same**: both force traffic through a security appliance. **Different**:
routing intent is **declarative and managed** (no UDRs; Microsoft programs the
hub), whereas the NVA pattern needs **you to write and maintain UDRs** and run
the NVA.

**Q10.** **vWAN** — at that scale (many VNets, multiple regions, branches) the
managed hub, automatic any-to-any, and hub-to-hub transit remove the peering
mesh and UDR sprawl a self-built hub would require.

</details>
