# Quiz — AZ-700 LB Lab 1: Standard Load Balancer

**Lab:** [`az700-lb-1-standard-load-balancer-walkthrough.md`](../labs/az700-lb-1-standard-load-balancer-walkthrough.md)
**Format:** 10 questions on SKUs, the five parts, and Layer-4 behaviour.
**Suggested time:** 10–15 minutes.

---

**Q1.** At which OSI layer does Azure Load Balancer operate, and what does that
mean it can and cannot route on?

(short answer)

---

**Q2.** Name three things Standard SKU gives you that Basic does not.

(short answer)

---

**Q3.** What is the *only* structural difference between a public and an
internal (private) load balancer?

(short answer)

---

**Q4.** What does the health probe do, and what happens to a backend that stops
answering it?

(short answer)

---

**Q5.** A load-balancing rule binds what to what?

(short answer)

---

**Q6.** Standard Load Balancer is "secure by default." What must you add for
traffic to actually reach the backends?

(short answer)

---

**Q7.** True/false with reason: a VM in a Standard LB backend pool has outbound
internet access by default.

(short answer)

---

**Q8.** You need to load-balance a non-HTTP protocol (e.g. a custom TCP service
on port 9000) across VMs. Load Balancer or Application Gateway?

(short answer)

---

**Q9.** What is HA Ports and which SKU offers it?

(short answer)

---

**Q10.** Repeated `curl` to the frontend returns `vm-lb1` then `vm-lb2` then
`vm-lb1`. What are you observing?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** **Layer 4** (transport). It routes on **protocol + IP + port** (TCP/UDP
flows) and **cannot** see or route on HTTP content (URL, host, headers).

**Q2.** Any three: availability-zone support, an SLA, HA Ports, larger backend
pools, outbound rules, secure-by-default, backend pool by IP. (Basic is legacy /
being retired, no SLA, no zones.)

**Q3.** The **frontend IP**: public LB uses a public IP, internal LB uses a
private IP in a subnet. Everything else (pool, probe, rules) is identical.

**Q4.** The probe periodically checks each backend; an **unhealthy** backend is
**removed from rotation** automatically (and re-added when it recovers) — the
self-healing part.

**Q5.** A **frontend IP + port** to a **backend pool + port** for a **protocol**,
using a **health probe** to select healthy members.

**Q6.** An **NSG rule** allowing the traffic (Standard LB is closed by default);
plus the backends need something listening on the backend port.

**Q7.** **False.** Standard LB backends have **no default outbound**; you must
add an **outbound rule** (or NAT gateway / public IP) to reach the internet.

**Q8.** **Load Balancer** — it is protocol-agnostic at L4 (any TCP/UDP port).
Application Gateway is HTTP/S only.

**Q9.** **HA Ports** load-balances **all ports** at once (a rule covering all
protocols/ports), used for NVAs/firewalls. **Standard** SKU only.

**Q10.** The load balancer **distributing flows across the healthy backend
pool** — both `vm-lb1` and `vm-lb2` are healthy and taking turns.

</details>
