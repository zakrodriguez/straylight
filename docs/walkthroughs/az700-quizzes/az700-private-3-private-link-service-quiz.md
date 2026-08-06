# Quiz — AZ-700 Private Lab 3: Private Link Service

**Lab:** [`az700-private-3-private-link-service-walkthrough.md`](../labs/az700-private-3-private-link-service-walkthrough.md)
**Format:** 10 questions on the provider side of Private Link.
**Suggested time:** 10–15 minutes.

---

**Q1.** Private endpoint vs Private Link Service — which is the consumer side and
which is the provider side?

(short answer)

---

**Q2.** What kind of load balancer must front a Private Link Service?

(short answer)

---

**Q3.** What is the NAT subnet for, and what setting must it have?

(short answer)

---

**Q4.** What do you hand a consumer so they can connect, and what do they create
to consume it?

(short answer)

---

**Q5.** Do the provider and consumer VNets need to be peered or share address
space?

(short answer)

---

**Q6.** What are the two controls a provider has over who connects?

(short answer)

---

**Q7.** A consumer's private endpoint targets a PLS. What does it target
specifically — a resource ID or an alias?

(short answer)

---

**Q8.** Why would a SaaS vendor use Private Link Service?

(short answer)

---

**Q9.** True/false with reason: a public Standard Load Balancer can front a
Private Link Service.

(short answer)

---

**Q10.** After a consumer requests a connection with manual approval, what does
the provider do?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** **Private endpoint = consumer** side (reach a service privately);
**Private Link Service = provider** side (publish your own service).

**Q2.** An **internal Standard Load Balancer** (internal frontend, Standard SKU
— not public, not Basic).

**Q3.** The PLS **source-NATs** consumer traffic using IPs from the NAT subnet,
so provider and consumer address spaces don't have to be coordinated. The subnet
must have **`privateLinkServiceNetworkPolicies` disabled**.

**Q4.** You hand them the **alias**; they create a **private endpoint** pointing
at that alias.

**Q5.** **No** — that's the point: Private Link connects them **without peering
or shared address space**, over the Microsoft backbone.

**Q6.** **Visibility** (who can see/request it — a role/sub allow-list or
"anyone with the alias") and **approval** (auto-approve vs manual).

**Q7.** The **alias** (not a resource ID) — the globally-unique
`<pls>.<guid>.<region>.azure.privatelinkservice` name.

**Q8.** To offer their service to customers **privately** — each customer
reaches it by private endpoint from their own VNet, no internet exposure and no
network peering/coordination.

**Q9.** **False** — a PLS requires an **internal** Standard LB frontend; a
public LB cannot front it.

**Q10.** **Approves** (or rejects) the pending connection — e.g.
`private-link-service connection update ... --connection-status Approved`.

</details>
