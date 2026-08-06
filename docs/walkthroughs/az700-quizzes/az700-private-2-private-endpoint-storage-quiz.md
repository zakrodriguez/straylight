# Quiz — AZ-700 Private Lab 2: Private Endpoint to Storage

**Lab:** [`az700-private-2-private-endpoint-storage-walkthrough.md`](../labs/az700-private-2-private-endpoint-storage-walkthrough.md)
**Format:** 10 questions on private endpoints and private DNS.
**Suggested time:** 10–15 minutes.

---

**Q1.** What does a private endpoint put in front of a PaaS service, and where?

(short answer)

---

**Q2.** What is a "sub-resource" / group ID, and give two for storage.

(short answer)

---

**Q3.** What is the exact private DNS zone name for a blob private endpoint, and
why must it be exactly that?

(short answer)

---

**Q4.** What must you do to the private DNS zone for a VM in the VNet to use it?

(short answer)

---

**Q5.** What does the private DNS zone *group* on the endpoint do?

(short answer)

---

**Q6.** From a VM in the VNet, `account.blob.core.windows.net` resolves to
`10.103.16.x`. Explain the resolution chain.

(short answer)

---

**Q7.** Service endpoint vs private endpoint — the one-line difference in what
each does to DNS.

(short answer)

---

**Q8.** Can a private endpoint be reached from a peered VNet? From on-premises?

(short answer)

---

**Q9.** True/false with reason: creating a private endpoint automatically stops
all public access to the storage account.

(short answer)

---

**Q10.** You created the endpoint and the zone but a VM still resolves the
public IP. Name the two most likely misconfigurations.

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** A **network interface with a private IP** from your VNet, in the
private-endpoint subnet — the service becomes reachable at that private address.

**Q2.** The specific service target a PE connects to. For storage:
**`blob`**, **`file`**, **`table`**, **`queue`**, **`dfs`**, **`web`** (any
two).

**Q3.** **`privatelink.blob.core.windows.net`**. Azure resolves the public name
to a CNAME `account.privatelink.blob.core.windows.net`, so a private zone by
**exactly** that name is what captures and redirects it to the private IP.

**Q4.** **Link** the private DNS zone to the VNet (a virtual-network link).

**Q5.** It **binds the endpoint to the zone** so Azure **auto-creates and
maintains the A record** (`account` → the PE's private IP) — no hand-managed
records.

**Q6.** The VM asks for `account.blob.core.windows.net` → Azure DNS returns a
**CNAME** to `account.privatelink.blob.core.windows.net` → the **linked private
zone** answers that with the **A record** to the PE's private IP (`10.103.16.x`).

**Q7.** **Service endpoint**: DNS **unchanged** (public IP). **Private
endpoint**: DNS **redirected** to a **private IP** via the `privatelink` zone.

**Q8.** **Yes** to both — because it's a private IP with private DNS, it's
reachable from **peered VNets** and from **on-prem over VPN/ExpressRoute**
(the latter needs hybrid DNS, Lab 4).

**Q9.** **False** — the PE adds private access; the account's
`publicNetworkAccess` / firewall is a **separate** setting you must also lock
down to remove public access.

**Q10.** The **VNet link** on the private DNS zone is missing, or the **DNS zone
group** (A record) wasn't created / points at the wrong sub-resource zone.

</details>
