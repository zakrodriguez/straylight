# Quiz — AZ-700 LB Lab 3: Web Application Firewall

**Lab:** [`az700-lb-3-web-application-firewall-walkthrough.md`](../labs/az700-lb-3-web-application-firewall-walkthrough.md)
**Format:** 10 questions on the WAF policy model, modes, and placement.
**Suggested time:** 10–15 minutes.

---

**Q1.** A WAF is not a load balancer. What is it, and what two Azure services
can host it?

(short answer)

---

**Q2.** What is the managed rule set on an Application Gateway WAF, and what
does it protect against?

(short answer)

---

**Q3.** Detection vs Prevention mode — what does each do, and which do you start
with?

(short answer)

---

**Q4.** Custom rules vs managed rules — when do custom rules evaluate, and in
what order?

(short answer)

---

**Q5.** What is an exclusion, and what problem does it solve?

(short answer)

---

**Q6.** Which Application Gateway tier is required to enforce a WAF?

(short answer)

---

**Q7.** You're in Prevention mode and a legitimate request is being blocked by
one managed rule. Name two ways to fix it without turning the WAF off.

(short answer)

---

**Q8.** Where do blocked/matched requests get logged, and why does that matter
for rollout?

(short answer)

---

**Q9.** App Gateway WAF vs Front Door WAF — what's the difference in *where*
the filtering happens?

(short answer)

---

**Q10.** How would you rate-limit requests per client IP on an App Gateway WAF?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** A WAF is an **HTTP rule engine** that inspects requests against attack
signatures before they reach the backend. On Azure it rides **Application
Gateway (WAF_v2)** or **Azure Front Door**.

**Q2.** The **OWASP Core Rule Set** (CRS; DRS on Front Door) — Microsoft-managed
signatures for SQL injection, XSS, RCE, protocol violations, etc.

**Q3.** **Detection** logs what *would* be blocked but blocks nothing;
**Prevention** actually blocks (403). **Start with Detection** to find false
positives before breaking real traffic.

**Q4.** Custom rules evaluate **before** the managed set, in **priority order**
(lowest number first); the first match's action wins.

**Q5.** An **exclusion** tells the WAF to skip a specific request attribute
(a header/cookie/arg) for the managed rules — so a legitimate value that trips
a rule doesn't force you to disable the rule for everyone.

**Q6.** **WAF_v2** (the WAF tier of Application Gateway v2).

**Q7.** Any two: add an **exclusion** for the tripping attribute; **disable the
specific rule** (by rule ID); tune with a **custom rule**; adjust the CRS
paranoia/version. (Not: turn off Prevention.)

**Q8.** The **`ApplicationGatewayFirewallLog`** (via diagnostic settings / Log
Analytics). It matters because you read it in **Detection** to clear false
positives before enabling **Prevention**.

**Q9.** App Gateway WAF filters at the **regional** gateway; Front Door WAF
filters at the **Microsoft edge (POP)**, dropping bad requests closer to the
client, before they reach a region.

**Q10.** A **RateLimitRule** custom rule (requests per minute per client IP /
match condition).

</details>
