# Quiz — AZ-700 DNS Lab 1: Private Zones, VNet Links, and Auto-Registration

**Lab:** `az700-dns-1-private-zones-walkthrough.md`
**Format:** 10 questions on private zone mechanics, the two link types,
auto-registration lifecycle, the wire server, and split-horizon behavior.
**Suggested time:** 10–15 minutes.

---

**Q1.** A private DNS zone has no servers to patch, size, or place. What
actually answers queries for it, and what single condition makes a VNet's
VMs able to resolve the zone at all?

(short answer)

---

**Q2.** Predict the output:

```bash
az network private-dns link vnet create --resource-group $RG \
  --zone-name internal.straylight.example --name link-spoke2-res \
  --virtual-network vnet-spoke2 --registration-enabled false \
  --query registrationEnabled -o tsv
```

(predict the output — exactly as az prints it)

---

**Q3.** Name the two virtual-network link types and the one capability that
separates them. Which records can a VM in a *resolution-only* linked VNet
resolve?

(short answer)

---

**Q4.** The three numeric limits the exam tests: registration links per
zone, resolution links per zone, and the number of private zones a single
VNet can auto-register into.

(three numbers)

---

**Q5.** `vm-spoke1` existed before the zone was created and before the
registration link existed — yet an A record for it appeared without anyone
creating it. Explain, and state what happens to that record when the VM is
deallocated or deleted.

(short answer)

---

**Q6.** What is `168.63.129.16`? State three facts about it worth knowing
cold for the exam.

(short answer)

---

**Q7.** A company hosts `app.contoso.com` publicly. A linked private zone
`contoso.com` also contains an `app` record with a private address. What
does a VM in the linked VNet get when it resolves `app.contoso.com`, and
what is this pattern called?

(short answer)

---

**Q8.** True or false, with the reason: a private DNS zone name must be
unique — you could not create `internal.straylight.example` in two
different subscriptions.

(short answer)

---

**Q9.** A teammate links a VNet to a private zone with auto-registration,
then tries to link the same VNet to a *second* zone with auto-registration.
What happens, and what is the correct design if VMs must be resolvable
under two names?

(short answer)

---

**Q10.** The lab added `myapp` → `10.101.0.250`, an address no VM holds.
Did the record-set creation succeed, and what does that tell you about what
DNS validates?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** Azure's resolver fabric answers (via the wire server at
`168.63.129.16`) — the zone is serverless name storage. A VNet's VMs can
resolve the zone only if that VNet has a **virtual-network link** to it;
no link, no answers, regardless of peering or routing.

**Q2.** `false` — the query projects the link's `registrationEnabled`
property, and az prints tsv booleans lowercase.

**Q3.** **Registration** links (platform may auto-create/delete VM records)
and **resolution** links (read-only). A VM in a resolution-only VNet
resolves **all** records in the zone — static and auto-registered alike;
the flag governs writing, never reading.

**Q4.** 100 registration links per zone, 1000 resolution links per zone,
and **one** zone per VNet for auto-registration.

**Q5.** Auto-registration back-fills: when a registration link appears,
the platform writes records for VMs already in the VNet (it can take a
minute — the lab polls). On deallocation or deletion the platform removes
the record automatically; the zone tracks reality without an operator.

**Q6.** Azure's wire server / virtual public IP: (1) it is the default DNS
recursor for every VNet and the path through which private zones answer;
(2) it is the same fixed address in every VNet, every region; (3) it is
reachable only from inside Azure (also serves IMDS/health duties) — it
never appears on the public internet.

**Q7.** The private zone's answer — the private address. Linked private
zones take precedence over public DNS for the same name; the pattern is
**split-horizon** (or split-brain) DNS, and it is how `privatelink.*`
zones make private endpoints resolve privately while the public name keeps
working for everyone else.

**Q8.** False. Private zone names are scoped by their links, not globally:
the same zone name can exist in any number of subscriptions or resource
groups. Only the set of VNets linked to each copy decides who sees which.

**Q9.** The second registration link is refused — a VNet auto-registers
into at most one zone. Correct design: register into one zone and link the
second zone resolution-only (static records or aliases there), or pick a
single registration zone that both names can live under.

**Q10.** It succeeded. DNS validates syntax, not existence — a record is
an assertion, not a probe. (Which is also why the alias record type in
Lab 2 exists: plain records can silently rot.)

</details>
