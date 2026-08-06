# Quiz — AZ-700 Private Lab 4: Hybrid Name Resolution to Private Endpoints

**Lab:** [`az700-private-4-hybrid-private-dns-walkthrough.md`](../labs/az700-private-4-hybrid-private-dns-walkthrough.md)
**Format:** 10 questions on hybrid private-endpoint DNS.
**Suggested time:** 10–15 minutes.

---

**Q1.** Why can't an on-premises host resolve an Azure private endpoint by
pointing at `168.63.129.16`?

(short answer)

---

**Q2.** What Azure component does on-prem forward its queries to instead, and
which endpoint of it?

(short answer)

---

**Q3.** What do you configure on the on-prem DNS server, and for which zone?

(short answer)

---

**Q4.** Which three prior building blocks does this lab compose?

(short answer)

---

**Q5.** For the resolver to answer for `privatelink.blob.core.windows.net`, what
must be true about that zone?

(short answer)

---

**Q6.** On-prem → Azure private resolution uses the resolver's *inbound*
endpoint. Which endpoint handles Azure → on-prem resolution?

(short answer)

---

**Q7.** What transport carries the DNS query from on-prem to the inbound
endpoint?

(short answer)

---

**Q8.** After wiring, `Resolve-DnsName myaccount.blob.core.windows.net` on dc1
returns `10.103.16.x`. Trace the path.

(short answer)

---

**Q9.** True/false with reason: you should create a conditional forwarder on
on-prem DNS pointing at the Azure wire server IP.

(short answer)

---

**Q10.** Name two `privatelink.*` zone names besides blob.

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** `168.63.129.16` is a **virtual public IP reachable only from inside
Azure** — it is not routable across the VPN/ExpressRoute tunnel.

**Q2.** The **DNS Private Resolver**, its **inbound endpoint** (a private IP in
the resolver's VNet).

**Q3.** A **conditional forwarder** for the **`privatelink.blob.core.windows.net`**
zone (and the other `privatelink.*` zones in use), pointing at the inbound
endpoint IP.

**Q4.** The **S2S tunnel** (hybrid module), the **DNS Private Resolver** (dns-3),
and a **private endpoint** + its `privatelink` zone (Lab 2).

**Q5.** It must be **linked to the resolver's VNet** (directly, or via a peered
VNet the zone is linked to) so the resolver can answer for it.

**Q6.** The **outbound** endpoint (with a forwarding ruleset) — dns-3's
Azure→on-prem direction.

**Q7.** The **S2S IPsec tunnel** (the query is just DNS/UDP-53 riding the
encrypted tunnel to the inbound endpoint's private IP).

**Q8.** dc1's conditional forwarder sends the query over the **tunnel** to the
**inbound endpoint** → the resolver answers from the **linked
`privatelink.blob` zone** → returns the **private endpoint IP** (10.103.16.x)
→ on-prem connects over the tunnel.

**Q9.** **False** — the wire server is unreachable from on-prem; forward to a
**resolver inbound endpoint** (or a DNS-forwarder VM) inside Azure instead.

**Q10.** Any two: `privatelink.database.windows.net` (SQL),
`privatelink.vaultcore.azure.net` (Key Vault),
`privatelink.file.core.windows.net` (Files),
`privatelink.azurewebsites.net` (App Service).

</details>
