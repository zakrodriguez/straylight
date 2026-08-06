# Quiz — AZ-700 LB Lab 5: Azure Front Door

**Lab:** [`az700-lb-5-front-door-walkthrough.md`](../labs/az700-lb-5-front-door-walkthrough.md)
**Format:** 10 questions on global L7, the object model, and the decision.
**Suggested time:** 10–15 minutes.

---

**Q1.** In one sentence, what is Azure Front Door and where does it run?

(short answer)

---

**Q2.** Name the Front Door object chain from client-facing name down to a
single backend.

(short answer)

---

**Q3.** Name two things Front Door does that Application Gateway cannot.

(short answer)

---

**Q4.** What is an origin group, and what two settings live on it?

(short answer)

---

**Q5.** Front Door and Traffic Manager are both global. Which is on the data
path, and what does the other one do instead?

(short answer)

---

**Q6.** Where does the Front Door WAF enforce, and why is that an advantage?

(short answer)

---

**Q7.** What does per-route caching buy you, and what regional service lacks it?

(short answer)

---

**Q8.** A common production stack layers Front Door, Application Gateway, and
Load Balancer. Sketch the order and what each does.

(short answer)

---

**Q9.** Standard vs Premium Front Door — name one Premium-only capability.

(short answer)

---

**Q10.** You need TLS terminated close to users worldwide, static content
cached at the edge, and a WAF before traffic enters any region. Which service?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** A **global Layer-7 reverse proxy on the Microsoft edge network** —
TLS offload, caching, WAF, and origin routing at the POP nearest the user.

**Q2.** **Profile → endpoint (`*.azurefd.net`) → route (paths) → origin group
(probe + LB settings) → origin (a backend, with priority/weight).**

**Q3.** Any two: **edge caching**, **edge TLS termination near the user**,
**edge WAF**, **global anycast entry**. (App Gateway is regional and can't
cache.)

**Q4.** The set of **origins (backends)** for a workload, carrying the
**health-probe** settings and the **load-balancing** settings (latency
sensitivity / sample size).

**Q5.** **Front Door** is on the data path (L7 proxy); **Traffic Manager** is
**DNS-only** (returns an address, never on the path).

**Q6.** At the **Microsoft edge (POP)** — bad requests are dropped **before they
enter any Azure region**, closer to the attacker/client.

**Q7.** Caching serves cacheable responses from the **POP nearest the user**,
cutting latency and origin load. **Application Gateway** (regional) can't cache.

**Q8.** **Front Door** (global edge: entry, caching, WAF, TLS) → **Application
Gateway** (regional L7 routing + regional WAF) → **Load Balancer** (L4 to the
VMs).

**Q9.** Premium adds **Private Link origins** and the **full managed WAF rule
set** (plus bot protection). (Either.)

**Q10.** **Azure Front Door** — global edge L7 with caching, TLS offload, and
an edge WAF.

</details>
