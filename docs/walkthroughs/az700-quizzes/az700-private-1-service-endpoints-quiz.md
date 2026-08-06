# Quiz — AZ-700 Private Lab 1: Service Endpoints

**Lab:** [`az700-private-1-service-endpoints-walkthrough.md`](../labs/az700-private-1-service-endpoints-walkthrough.md)
**Format:** 10 questions on service endpoints vs the alternatives.
**Suggested time:** 10–15 minutes.

---

**Q1.** A service endpoint is a property of what object?

(short answer)

---

**Q2.** What two things does enabling a service endpoint change, and what does
it *not* change?

(short answer)

---

**Q3.** After you enable the endpoint, what must you also do on the PaaS service
for the restriction to take effect?

(short answer)

---

**Q4.** Does a service endpoint change the DNS name or IP the service resolves
to?

(short answer)

---

**Q5.** Can an on-premises host reach a storage account over a service endpoint
across a VPN/ExpressRoute connection?

(short answer)

---

**Q6.** From a VM in the allowed subnet, a request to the storage endpoint
returns HTTP 400. From anywhere else it times out. What does the 400 tell you?

(short answer)

---

**Q7.** True/false with reason: with a service endpoint and a firewall lock, the
storage account no longer has a public IP.

(short answer)

---

**Q8.** Name two limitations of service endpoints that private endpoints solve.

(short answer)

---

**Q9.** You need to allow one specific subnet to reach Azure Storage over the
backbone but keep everyone else out. Service endpoint or private endpoint —
which is the lighter tool that fits?

(short answer)

---

**Q10.** What is a service endpoint *policy* (one sentence)?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** The **subnet** (you enable a service class like `Microsoft.Storage` on
the subnet).

**Q2.** It changes the **route** (traffic to the service rides the Azure
backbone) and lets you lock the service **firewall** to the subnet. It does
**not** change the service's public IP or DNS name.

**Q3.** Lock the service **firewall** (network rules): default action **Deny**
plus **allow the subnet** — the endpoint alone doesn't restrict anything.

**Q4.** **No** — the service keeps its **public name and public IP**; only the
path and firewall change.

**Q5.** **No** — service endpoints don't extend to on-prem over VPN/ER (the
source must be the flagged Azure subnet). Private endpoints do.

**Q6.** The request **reached** storage over the service endpoint and got an
**application-level** error (auth/query) — connectivity works; a firewall block
would time out instead.

**Q7.** **False** — the account **keeps its public IP/endpoint**; the firewall
just denies everyone except the allowed subnet. (Removing the public endpoint is
what a **private endpoint** does.)

**Q8.** Any two: no **on-prem reach** over VPN/ER; still a **public endpoint**
(no private IP); **service/region-class** granularity vs a specific resource;
no cross-region by default. Private endpoints give a **private IP**, **on-prem
reach**, and per-resource targeting.

**Q9.** **Service endpoint** — it's the lighter tool for "let this subnet reach
the PaaS class over the backbone, deny the rest," with no private IP/DNS to
manage.

**Q10.** A **service endpoint policy** further restricts service-endpoint
traffic to **specific PaaS resources** (e.g. only *these* storage accounts),
not the whole service class.

</details>
