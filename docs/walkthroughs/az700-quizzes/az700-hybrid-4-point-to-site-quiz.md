# Quiz — AZ-700 Hybrid Lab 4: Point-to-Site VPN

**Lab:** [`az700-hybrid-4-point-to-site-walkthrough.md`](../labs/az700-hybrid-4-point-to-site-walkthrough.md)
**Format:** 10 questions on the P2S profile, protocols, and auth models.
**Suggested time:** 10–15 minutes.

---

**Q1.** In one sentence each, what does site-to-site connect, and what does
point-to-site connect?

(short answer)

---

**Q2.** Is point-to-site a new Azure resource? Where is it configured?

(short answer)

---

**Q3.** The P2S client address pool: whose address space does it draw from,
and what must it not overlap?

(short answer)

---

**Q4.** Name the three P2S tunnel protocols. Which one also supports
Microsoft Entra ID authentication?

(short answer)

---

**Q5.** Name the three P2S authentication models.

(short answer)

---

**Q6.** With Azure-certificate auth, what is uploaded to the gateway, and
what does each client present?

(short answer)

---

**Q7.** How does a P2S client get its configuration — do you hand-configure
each one?

(short answer)

---

**Q8.** Does P2S create a local network gateway or a connection object like
S2S does? Why or why not?

(short answer)

---

**Q9.** What must the gateway be (type) for P2S, and can a Basic SKU do it?

(short answer)

---

**Q10.** A developer needs to reach VNet resources from a laptop on a coffee
-shop network, with no on-prem gateway involved. S2S or P2S, and why?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** S2S connects a whole **network** (an on-prem site, via its gateway) to
an Azure VNet. P2S connects a **single client** (a laptop/host) to the VNet
over its own per-client tunnel.

**Q2.** No — P2S is a **profile on the existing virtual network gateway**
(`vpnClientConfiguration`), not a new resource.

**Q3.** The pool is **Azure-side** — each client leases an address from it. It
must not overlap the **VNet address space** (`10.100.0.0/14`) or the
**on-prem space** (`192.168.56.0/21`); the lab uses `172.16.201.0/24`.

**Q4.** **OpenVPN**, **IKEv2**, and **SSTP**. **OpenVPN** also supports
**Microsoft Entra ID** auth.

**Q5.** **Azure certificate**, **Microsoft Entra ID** (OpenVPN only), and
**RADIUS**.

**Q6.** A **root certificate** (its public data) is uploaded to the gateway;
each client presents a **leaf certificate signed by that root**.

**Q7.** The gateway **generates a client profile package** (embedded with the
gateway address + trusted root); the client imports it into the OpenVPN or
native VPN client. No per-client server config.

**Q8.** **No.** P2S has **no on-prem side to model** — no LNG, no connection.
It is entirely a setting on the gateway; clients are transient.

**Q9.** The gateway must be **route-based** (policy-based cannot do P2S).
**Basic SKU cannot** — P2S needs a VpnGw1+/AZ SKU.

**Q10.** **P2S** — it connects an individual client with no on-prem
infrastructure; S2S would require a gateway/router at the coffee shop, which
is absurd for one laptop.

</details>
