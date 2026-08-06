# Quiz — AZ-700 LB Lab 2: Application Gateway URL-Path Routing

**Lab:** [`az700-lb-2-application-gateway-routing-walkthrough.md`](../labs/az700-lb-2-application-gateway-routing-walkthrough.md)
**Format:** 10 questions on Layer-7 routing, listeners, and the path map.
**Suggested time:** 10–15 minutes.

---

**Q1.** At which layer does Application Gateway operate, and name two things it
can route on that a Load Balancer cannot.

(short answer)

---

**Q2.** What does a listener bind together?

(short answer)

---

**Q3.** What is a URL-path map, and what are its two kinds of destination?

(short answer)

---

**Q4.** Why does Application Gateway require its own dedicated subnet?

(short answer)

---

**Q5.** Standard_v2 vs v1 — name two v2 advantages.

(short answer)

---

**Q6.** A request to `/images/logo.png` reaches `vm-appgw2` while `/` reaches
`vm-appgw1`, through one gateway and one listener. What made the choice?

(short answer)

---

**Q7.** Path-based routing vs host-based (multi-site) routing — one line each.

(short answer)

---

**Q8.** Application Gateway takes ~15–20 minutes to provision. What does that
imply for how the labs deploy it (vs creating it in a lab step)?

(short answer)

---

**Q9.** Which Application Gateway tier hosts the WAF?

(short answer)

---

**Q10.** You need global HTTP routing with caching at the edge, not regional.
Is Application Gateway the right tool? If not, what is?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** **Layer 7** (application/HTTP). It can route on **URL path** and **host
header** (also cookies/headers, do header rewrite, terminate TLS) — none of
which a Layer-4 Load Balancer can see.

**Q2.** A **frontend IP + a frontend port + a protocol** (HTTP/HTTPS) — it is
what receives the client request before routing.

**Q3.** The Layer-7 routing table: a **default backend pool** for unmatched
requests plus **path rules** that send matching URL paths to other pools. The
two destinations are the **default pool** and the **path-rule pools**.

**Q4.** App Gateway deploys its instances into the subnet and requires it be
**dedicated** (no other resources) — it manages that subnet's IPs and needs the
address space to scale.

**Q5.** Any two: autoscaling, zone redundancy, static VIP, header rewrite,
faster provisioning/updates, WAF_v2. (v1 is legacy.)

**Q6.** The **URL-path map**: `/images/*` matched a path rule pointing at
`pool-images` (vm-appgw2); `/` fell through to the default pool `pool-default`
(vm-appgw1).

**Q7.** **Path-based**: same hostname, route by URL path (`/images/*` →
pool B). **Host-based (multi-site)**: multiple listeners by **host header**
(`app1.contoso.com` vs `app2.contoso.com`) on one gateway.

**Q8.** Long-running resources are **deployed by the topology/script and gated
with `az700.sh watch`**, never provisioned inside a lab step (a step would hang
past the walkverify timeout).

**Q9.** **WAF_v2** (the WAF tier of Application Gateway v2).

**Q10.** **No** — App Gateway is **regional** and can't cache. Global L7 with
edge caching is **Azure Front Door**.

</details>
