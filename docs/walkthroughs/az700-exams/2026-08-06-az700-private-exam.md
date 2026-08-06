# AZ-700 Module Exam — Private Access (Service Endpoints & Private Link)

**Module:** az700-private (Labs 1–4: service endpoints, private endpoint to
storage, Private Link Service, hybrid private-endpoint DNS).
**Format:** 24 questions in four sections — service endpoints (1–6), private
endpoints & DNS (7–14), Private Link Service (15–19), hybrid DNS (20–24).
Mixed multiple-choice and short answer.
**Suggested time:** 45–60 minutes, closed book.

---

## Section 1 — Service endpoints

**Q1.** A service endpoint is enabled on which object?

a) The storage account
b) The subnet
c) The VNet
d) The NIC

---

**Q2.** Name the two things a service endpoint changes and the one thing it does
not.

(short answer)

---

**Q3.** After enabling the endpoint, what makes the restriction actually take
effect?

(short answer)

---

**Q4.** True/false with reason: a service endpoint gives the storage account a
private IP.

(short answer)

---

**Q5.** Can on-premises hosts use a service endpoint over ExpressRoute?

(short answer)

---

**Q6.** What does a service endpoint *policy* add?

(short answer)

---

## Section 2 — Private endpoints & private DNS

**Q7.** What does a private endpoint place in the VNet?

(short answer)

---

**Q8.** For a blob private endpoint, the private DNS zone must be named exactly:

a) `blob.core.windows.net`
b) `privatelink.blob.core.windows.net`
c) `private.blob.azure.com`
d) `blob.privatelink.azure.net`

---

**Q9.** Why that exact name — what does Azure DNS do with the public name?

(short answer)

---

**Q10.** Two steps make the zone usable for a VNet's VMs and keep its records
current. Name both.

(short answer)

---

**Q11.** What is a group ID / sub-resource? Give two for storage.

(short answer)

---

**Q12.** True/false with reason: creating a private endpoint blocks public
access to the account.

(short answer)

---

**Q13.** From a peered VNet, can a client reach the private endpoint? What about
resolving its name?

(short answer)

---

**Q14.** Service endpoint vs private endpoint — the single sharpest difference.

(short answer)

---

## Section 3 — Private Link Service

**Q15.** Private Link Service is which side of Private Link, and what must front
it?

a) Consumer side; a public LB
b) Provider side; an internal Standard LB
c) Consumer side; an App Gateway
d) Provider side; a Basic LB

---

**Q16.** What is the NAT subnet for, and what network-policy setting does it
need?

(short answer)

---

**Q17.** What do you give consumers, and what do they create to connect?

(short answer)

---

**Q18.** Do the provider and consumer networks need peering or shared address
space?

(short answer)

---

**Q19.** Name the provider's two connection controls.

(short answer)

---

## Section 4 — Hybrid private-endpoint DNS

**Q20.** Why can't on-prem resolve a private endpoint via `168.63.129.16`?

(short answer)

---

**Q21.** What does on-prem forward to instead?

a) The wire server across the tunnel
b) The DNS Private Resolver inbound endpoint
c) Public Azure DNS
d) The private endpoint's IP directly

---

**Q22.** What do you configure on the on-prem DNS server, for which zone, and
pointing where?

(short answer)

---

**Q23.** For the resolver to answer for the `privatelink` zone, what must be
true of that zone?

(short answer)

---

**Q24.** Design scenario: an on-prem app must reach an Azure storage account
**privately** by its normal name, over the existing S2S VPN. List the four
pieces you deploy/configure.

(short answer)

---

## Answers

### Section 1

**Q1.** **b)** The subnet.

**Q2.** Changes the **route** (backbone) and enables locking the service
**firewall** to the subnet; does **not** change the service's public IP/DNS.

**Q3.** Locking the service **firewall**: default action **Deny** + **allow the
subnet**.

**Q4.** **False** — the account keeps its **public** endpoint; a private IP is
what a **private endpoint** provides.

**Q5.** **No** — service endpoints don't extend to on-prem over VPN/ER.

**Q6.** It restricts service-endpoint traffic to **specific PaaS resources** (a
resource allow-list), not the whole service class.

### Section 2

**Q7.** A **network interface with a private IP** (in the PE subnet).

**Q8.** **b)** `privatelink.blob.core.windows.net`.

**Q9.** Azure DNS returns a **CNAME** from the public name to
`account.privatelink.blob.core.windows.net`; the private zone by that exact
name resolves the CNAME target to the private IP.

**Q10.** **Link** the zone to the VNet, and create a **DNS zone group** on the
endpoint (auto-maintains the A record).

**Q11.** The specific service target of the PE. Storage: any two of **blob,
file, table, queue, dfs, web**.

**Q12.** **False** — public access is a **separate** setting
(`publicNetworkAccess` / firewall) you must also lock.

**Q13.** **Yes** it's reachable (private IP is routable from the peer), and the
name resolves **if** the `privatelink` zone is also **linked to the peered
VNet** (or shared).

**Q14.** A **private endpoint** gives a **private IP + private DNS**; a
**service endpoint** leaves the service **public** and only fences the firewall.

### Section 3

**Q15.** **b)** Provider side; an **internal Standard LB**.

**Q16.** It **source-NATs** consumer traffic (so address spaces needn't be
coordinated); the subnet needs **`privateLinkServiceNetworkPolicies`
disabled**.

**Q17.** Give them the **alias**; they create a **private endpoint** targeting
it.

**Q18.** **No** — Private Link connects them without peering or shared address
space.

**Q19.** **Visibility** (who can request) and **approval** (auto vs manual).

### Section 4

**Q20.** `168.63.129.16` is reachable **only from inside Azure** — not routable
across the tunnel.

**Q21.** **b)** The DNS Private Resolver **inbound endpoint**.

**Q22.** A **conditional forwarder** for the **`privatelink.blob.core.windows.net`**
zone, pointing at the **inbound endpoint's private IP**.

**Q23.** It must be **linked to the resolver's VNet** so the resolver can answer
for it.

**Q24.** (1) A **private endpoint** on the storage account +
**`privatelink.blob`** zone; (2) a **DNS Private Resolver** with an **inbound
endpoint**, with the zone linked to its VNet; (3) the **S2S tunnel** (already
present); (4) a **conditional forwarder** on on-prem DNS for the `privatelink`
zone → the inbound endpoint IP.
