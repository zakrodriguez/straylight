# Quiz — AZ-700 DNS Lab 3: DNS Private Resolver

**Lab:** [`az700-dns-3-private-resolver-walkthrough.md`](../labs/az700-dns-3-private-resolver-walkthrough.md)
**Format:** 10 questions on endpoints, rulesets, and hybrid resolution.
**Suggested time:** 10–15 minutes.

---

**Q1.** How many VNets is a DNS Private Resolver bound to?

(short answer)

---

**Q2.** What is the inbound endpoint, and which direction of resolution does
it serve?

(short answer)

---

**Q3.** What two resources drive the reverse direction (Azure → on-prem), and
what does each do?

(short answer)

---

**Q4.** The resolver's endpoint subnets have a special requirement. What is
it?

(short answer)

---

**Q5.** Can the inbound and outbound endpoints share one subnet?

(short answer)

---

**Q6.** A forwarding rule's `domainName` is `straylight.lab.` with a trailing
dot. Why the dot?

(short answer)

---

**Q7.** A forwarding ruleset exists but a VNet's queries ignore it. What is
probably missing?

(short answer)

---

**Q8.** What did DNS Private Resolver replace, and name one advantage over it.

(short answer)

---

**Q9.** On-prem `dc1` needs to resolve Azure private-zone names. What do you
configure on `dc1`, and what address do you point it at?

(short answer)

---

**Q10.** In the standalone lab the forwarding rule to on-prem does not return
a live answer. Why, and what makes it work?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** **Exactly one** — a resolver is regional and bound to a single VNet.

**Q2.** The inbound endpoint is a **private IP inside the resolver's VNet**
that listens for DNS queries; it serves **on-prem → Azure** (on-prem forwards
Azure-domain queries to it).

**Q3.** The **outbound endpoint** (the resolver's egress) and a **forwarding
ruleset** (rules of the form "domain X → these DNS servers"). Together they
send chosen domains **out to on-prem DNS**.

**Q4.** Each endpoint subnet must be **delegated to
`Microsoft.Network/dnsResolvers`** (and be at least a /28, otherwise empty).

**Q5.** **No** — inbound and outbound endpoints require **separate** delegated
subnets.

**Q6.** Forwarding rules match **fully-qualified domain names**; the trailing
dot marks the FQDN (root-anchored) form.

**Q7.** A **virtual-network link** from the ruleset to that VNet — a ruleset
only applies to VNets it is **linked** to.

**Q8.** It replaced a **DNS-forwarder VM**. Advantages (any one): **managed**
(no VM to patch/scale), **central** conditional-forwarding policy across
linked VNets, no single-VM failure point.

**Q9.** A **conditional forwarder** on `dc1` for the Azure private-zone domain,
pointed at the **inbound endpoint's private IP**.

**Q10.** The rule's target (`192.168.56.10`, on-prem `dc1`) is reachable
**only over the S2S tunnel**; standing up `hybrid-vpn` so the resolver VNet
routes to on-prem makes the forwarded query resolve.

</details>
