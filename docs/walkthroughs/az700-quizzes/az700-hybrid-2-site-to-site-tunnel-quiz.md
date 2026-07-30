# Quiz — AZ-700 Hybrid Lab 2: The Site-to-Site Tunnel

**Lab:** [`az700-hybrid-2-site-to-site-tunnel-walkthrough.md`](../labs/az700-hybrid-2-site-to-site-tunnel-walkthrough.md)
**Format:** 10 questions on IKEv2 negotiation, traffic selectors,
reachability, and on-prem routing.
**Suggested time:** 10–15 minutes.

---

**Q1.** `sudo swanctl --list-sas` shows `ESTABLISHED` and a child SA
`INSTALLED`, but `az ... connectionStatus` still reads `NotConnected`. Is
the tunnel up? Explain.

(short answer)

---

**Q2.** What are traffic selectors, and what are the two prefixes on this
tunnel? What happens to a packet whose endpoints don't both fall inside
that pair?

(short answer)

---

**Q3.** The initiate fails with `NO_PROPOSAL_CHOSEN`. What layer failed,
and what is the fix?

(short answer)

---

**Q4.** In this design, which side initiates the tunnel and which responds?
Why does that choice matter for a lab behind a home router?

(short answer)

---

**Q5.** `vpn1` can ping `10.100.2.4` (an Azure VM) but `dc1` cannot, even
though both are on the lab network. What is missing on dc1, and what
provides it?

(short answer)

---

**Q6.** The Azure VM at `10.100.2.4` has no public IP. Explain, in terms of
selectors and routing, how a ping from the lab reaches it and gets a reply.

(short answer)

---

**Q7.** Predict the two lines:

```bash
sudo swanctl --list-sas --child azure | grep -E 'local|remote'
```

(predict)

---

**Q8.** After the tunnel is up and a ping has succeeded, `connectionStatus`
is still `NotConnected`. What do you do?

(short answer)

---

**Q9.** What does it mean that "the whole on-prem site rides one tunnel
endpoint"? How many VPN configurations does a second on-prem host need?

(short answer)

---

**Q10.** Which two signals are authoritative for "the tunnel is up", and
which one is a lagging confirmation?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** **Yes, it's up.** The `swanctl` SA state is the on-prem end of the
negotiation and is true the instant crypto agrees. Azure's
`connectionStatus` updates from gateway telemetry on a lagging cadence
(minutes) — it trails the data plane, it doesn't gate it.

**Q2.** Traffic selectors are the local/remote prefixes the tunnel
encrypts: `192.168.56.0/21` (on-prem supernet) ⇔ `10.100.0.0/14` (Azure
pool). A packet not matching both is **not encrypted into the tunnel** — it
takes the normal (non-tunnel) path or is dropped; a selector mismatch is a
silent "tunnel up, no traffic" failure.

**Q3.** **IKE (Phase 1) crypto negotiation** failed — no shared proposal.
Fix: pin an explicit, **identical** IPsec/IKE policy on both ends
(AES256/SHA256/DHGroup14 IKE, AES256/SHA256 no-PFS ESP here). Azure's
default policy set caused exactly this against strongSwan.

**Q4.** **vpn1 initiates; Azure responds.** The lab is behind VBox NAT and
a home router (double NAT); as the initiator it only needs outbound
UDP/500+4500, so **no inbound port-forward** is required at home. NAT-T
carries the tunnel.

**Q5.** dc1 lacks a **route** to the Azure pool. The `azure_routes` role
adds a persistent `10.100.0.0/14 → vpn1` route; dc1 then sends Azure-bound
packets to vpn1, which forwards them into the SA.

**Q6.** The lab source (`192.168.56.x`) and Azure destination
(`10.100.2.4`) both fall inside the selector pair, so vpn1 encrypts the
packet into the tunnel; the gateway decrypts and delivers it inside the
hub VNet. The reply's endpoints also match the selectors, so the gateway
routes it back down the tunnel — no public IP is ever involved.

**Q7.** `local  192.168.56.0/21` and `remote 10.100.0.0/14`.

**Q8.** **Wait a minute and re-run** — it's the known control-plane lag.
The ping already proved the data plane. Do not tear anything down.

**Q9.** One VPN endpoint (vpn1) carries the tunnel; every host that has the
`azure_routes` route reaches Azure through it. A second on-prem host needs
**zero** VPN configuration — just the route (or a default route via vpn1).

**Q10.** Authoritative: the **`swanctl` SA state** and an **actual ping**
across the tunnel. Lagging confirmation: Azure's **`connectionStatus`**.

</details>
