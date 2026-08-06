# Quiz — AZ-700 LB Lab 4: Traffic Manager

**Lab:** [`az700-lb-4-traffic-manager-walkthrough.md`](../labs/az700-lb-4-traffic-manager-walkthrough.md)
**Format:** 10 questions on DNS-based routing, methods, and endpoints.
**Suggested time:** 10–15 minutes.

---

**Q1.** How does Traffic Manager direct traffic, and what does that mean it
never does?

(short answer)

---

**Q2.** Name the five routing methods and one line on each.

(short answer)

---

**Q3.** A client is served the wrong (old) endpoint for a while after a
failover. Why, and what setting controls the window?

(short answer)

---

**Q4.** Name the three endpoint types.

(short answer)

---

**Q5.** Traffic Manager vs Load Balancer — one is global and one is regional.
Which is which, and which one is on the data path?

(short answer)

---

**Q6.** Which routing method sends a user to the lowest-latency endpoint? Which
sends by the user's geographic region?

(short answer)

---

**Q7.** What does the health monitor do, and what happens to an endpoint that
fails it?

(short answer)

---

**Q8.** You want to combine routing methods (e.g. geographic first, then
performance within a region). What endpoint type enables that?

(short answer)

---

**Q9.** Can Traffic Manager and Front Door both be "global"? How do they
differ?

(short answer)

---

**Q10.** Resolving `<profile>.trafficmanager.net` returns the load balancer's
IP. Walk through what just happened.

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** Via **DNS** — it returns the chosen endpoint's address at resolution
time; the client then connects **directly**. So it **never sees a packet / is
never on the data path**.

**Q2.** **Priority** (ordered failover), **Weighted** (round-robin by weight),
**Performance** (lowest latency to the client), **Geographic** (by client
region), **MultiValue** (return several healthy endpoints at once).

**Q3.** DNS answers are **cached until the record's TTL expires**; the client
keeps using the old answer until then. The profile **TTL** controls the window.

**Q4.** **Azure endpoints** (Azure resources), **external endpoints** (any
FQDN/IP), **nested endpoints** (another Traffic Manager profile).

**Q5.** **Traffic Manager = global**, **Load Balancer = regional**. The **Load
Balancer** is on the data path; Traffic Manager is not (DNS only).

**Q6.** **Performance** → lowest latency. **Geographic** → by the user's region.

**Q7.** The monitor probes each endpoint (HTTP/HTTPS/TCP); a **failing endpoint
is removed from DNS answers** (and restored when it recovers).

**Q8.** **Nested endpoints** — a parent profile points at child profiles, so you
layer methods (e.g. Geographic parent, Performance child).

**Q9.** Yes. **Traffic Manager** is DNS-only (not on the path, works for any
service). **Front Door** is a global **L7 proxy on the edge** (on the path,
caching + WAF, HTTP/S only).

**Q10.** The client asked DNS for the profile FQDN → Traffic Manager applied the
**routing method** (Priority) over the **healthy** endpoints → returned the
**priority-1** endpoint's address (the load balancer's IP) as the DNS answer.

</details>
