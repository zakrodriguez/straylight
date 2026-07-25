# Quiz — AZ-700 DNS Lab 2: Public Zones, Record Sets, and Alias Records

**Lab:** `az700-dns-2-public-zones-alias-walkthrough.md`
**Format:** 10 questions on public zone anatomy, delegation, TTL
mechanics, CNAME constraints, and alias records.
**Suggested time:** 10–15 minutes.

---

**Q1.** Creating a public zone instantly wrote two record sets that can
never be deleted. Name them and state what each is for.

(short answer)

---

**Q2.** Azure assigned the zone four name servers spread across
`azure-dns.com`, `.net`, `.org`, and `.info`. Why four different TLDs?

(short answer)

---

**Q3.** The lab's zone answers `dig @<ns>` queries from anywhere on the
internet, yet `nslookup www.straylight.example` from a random machine
fails. Reconcile the two facts, and name the single action that would make
public resolution work for a real domain.

(short answer)

---

**Q4.** Predict the output:

```bash
NS=$(az network dns zone show --resource-group $RG \
  --name straylight.example --query "nameServers[0]" -o tsv)
dig +short @$NS docs.straylight.example
```

given `docs` is a CNAME to `www.straylight.example` and `www` is an A
record for `203.0.113.10`.

(predict the output)

---

**Q5.** You are about to repoint `www` at a new address. The record set's
TTL is 3600. Describe the standard migration sequence and why it works.

(short answer)

---

**Q6.** Two CNAME constraints the exam tests: how many records a CNAME
record set may hold, and where in the zone a CNAME may never exist.

(short answer)

---

**Q7.** What does an alias record target instead of an address, name three
Azure resource types it can point at, and state the two lifecycle behaviors
that make it better than a hand-typed A record.

(short answer)

---

**Q8.** A customer needs `contoso.com` itself (no `www`) to reach an Azure
public IP. A CNAME is illegal there. What is the sanctioned answer?

(short answer)

---

**Q9.** The alias exercise deleted nothing, but suppose `pip-dnslab` were
deleted while the alias record remained. What would `dig` return for
`app.straylight.example`, and how does that differ from the `www` record's
behavior if its address died?

(short answer)

---

**Q10.** Which record types support the alias feature in Azure DNS, and
can an alias point at something that is not an Azure resource at all?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** **SOA** (zone authority metadata — serial, refresh timers, the
zone's primary NS) and **NS** (the delegation set — which servers are
authoritative). Every zone has exactly one of each at the apex; Azure
manages them and they cannot be removed.

**Q2.** Fault isolation: if a TLD registry or its infrastructure has an
outage, three of the four name servers still resolve. It is availability
engineering applied to the delegation chain itself.

**Q3.** `dig @<ns>` asks Azure's authoritative servers directly, skipping
the delegation chain; ordinary resolution starts at the root and stops —
`.example` is a reserved TLD with no delegation to these servers (and for
a real name, the registrar simply hasn't been told). The one action for a
real domain: enter the four Azure NS names at the registrar — delegation
is the entire go-live.

**Q4.** Two lines: `www.straylight.example.` then `203.0.113.10` — dig
follows the CNAME and prints the chain, target name first, then the
resolved A record.

**Q5.** Lower the TTL (say to 60) and wait out the *old* TTL so caches
world-wide pick up the short lease; make the address change — staleness
now lasts at most 60 s; raise the TTL back once stable. Works because TTL
is a cache lease and the change window inherits whichever TTL caches
already hold.

**Q6.** A CNAME record set holds exactly **one** record, and a CNAME may
never exist at the **zone apex** (the zone name itself) — it cannot
coexist with the mandatory SOA/NS there.

**Q7.** It targets an Azure **resource ID**. Valid targets include public
IP addresses, Traffic Manager profiles, CDN endpoints, Front Door
endpoints (and another record set in the same zone). Lifecycle: the answer
**updates automatically** when the resource's address changes, and the
record **empties itself** when the resource is deleted — no rot, no stale
answers.

**Q8.** An **alias A record at the apex** targeting the public IP (or
Traffic Manager/Front Door profile). Alias-at-apex is precisely the
feature's reason to exist.

**Q9.** The alias would return nothing (NXDOMAIN/empty — the record
empties itself). The `www` A record has no such link: it would keep
serving `203.0.113.10` indefinitely, correct or not — DNS asserts, it
never checks.

**Q10.** A, AAAA, and CNAME record sets support alias mode. No — an alias
points only at Azure resources (or another record set in the same zone);
for arbitrary external names you use an ordinary CNAME.

</details>
