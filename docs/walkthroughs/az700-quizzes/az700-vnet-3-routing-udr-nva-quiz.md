# Quiz — AZ-700 VNet Lab 3: System Routes, UDRs, and an NVA Next Hop

**Lab:** `az700-vnet-3-routing-udr-nva-walkthrough.md`
**Format:** 10 questions on route sources, `nextHopType`
vocabulary, longest-prefix-match and source precedence, fabric
vs OS IP forwarding, UDR mechanics, and forced tunneling.
**Suggested time:** 10–15 minutes.

---

**Q1.** Every route has a source. Name the three sources and the
exact string each one shows in effective-route-table output.

(short answer)

---

**Q2.** Match each `nextHopType` to its meaning:

| nextHopType | Meaning |
|---|---|
| `VnetLocal` | __________ |
| `VNetPeering` | __________ |
| `VirtualAppliance` | __________ |
| `VirtualNetworkGateway` | __________ |
| `None` | __________ |

(choices: delivered directly inside the VNet; cross a peering;
forward to a specific IP address — an NVA; into a
VPN/ExpressRoute tunnel; drop the packet — a black-hole route)

---

**Q3.** A subnet has a /24 system route and a /16 UDR that both
cover the destination. Which route carries the packet? State the
full two-stage selection rule.

(short answer)

---

**Q4.** An exam answer pairs `--next-hop-ip-address` with next-hop
type `Internet`. Why is it wrong before you even read the
scenario?

(short answer)

---

**Q5.** Fill in the two blanks to steer spoke2-bound traffic
through the NVA:

```bash
az network route-table route create --resource-group $RG \
  --route-table-name rt-spoke1 --name to-spoke2-via-nva \
  --address-prefix 10.102.0.0/24 --next-hop-type __________ \
  --__________ $NVAIP
```

(next-hop type + flag name)

---

**Q6.** An NVA needs two halves of IP forwarding. Name both,
state which level each lives at (and what kind of property it
is), and say which half is missing when the fabric delivers
packets but the kernel drops them.

(short answer)

---

**Q7.** `rt-spoke1` holds the UDR and was just associated with
`snet-workload`. Predict the output, and state when the route
took effect on the subnet's VMs:

```bash
az network nic show-effective-route-table --resource-group $RG \
  --name nic-vm-spoke1 \
  --query "length(value[?source=='User' && nextHopType=='VirtualAppliance'])" -o tsv
```

(predict the output + timing)

---

**Q8.** Route-table object model: is a route table a standalone
resource, what makes it take effect, how many tables can a subnet
have, and can one table serve several subnets?

(short answer)

---

**Q9.** The NVA behind a UDR is deallocated. What do the `az`
resources still report, what does the effective route show, and
what happens to traffic for the UDR's prefix?

(short answer)

---

**Q10.** "We added a `0.0.0.0/0` route to the firewall and now
nothing can download updates." Explain the blast radius of that
UDR and name the artifact where the problem gets diagnosed.

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** System routes Azure creates for you — `Default`; user
routes you write (UDRs) — `User`; routes learned from a gateway
via BGP — `VirtualNetworkGateway`.

**Q2.**
- `VnetLocal` → delivered directly inside the VNet
- `VNetPeering` → cross a peering
- `VirtualAppliance` → forward to a specific IP address — an NVA
- `VirtualNetworkGateway` → into a VPN/ExpressRoute tunnel
- `None` → drop the packet — a black-hole route

**Q3.** The /24 system route. Azure matches on longest prefix
first, always; source precedence (**User > BGP > System**) breaks
the tie only when two routes have the *same* prefix. Precedence
never overrides prefix length — exam questions love implying
otherwise.

**Q4.** `VirtualAppliance` is the only next-hop type that takes
an IP address — `--next-hop-ip-address` is required with it and
rejected with every other type. Pairing an IP with `Internet`,
`None`, or `VirtualNetworkGateway` is wrong on syntax alone.

**Q5.** `--next-hop-type VirtualAppliance` and
`--next-hop-ip-address $NVAIP`.

**Q6.** Fabric-level: `enableIPForwarding` — a NIC property (not
a VM property, not an OS setting) that makes the fabric deliver
packets not addressed to that NIC. OS-level:
`net.ipv4.ip_forward=1` on Linux, so the kernel forwards what the
fabric delivers. If the fabric delivers but the kernel drops, the
OS half is missing.

**Q7.** `1`. The UDR became live on every NIC in the subnet the
moment the route table was associated — no reboot needed. It
appears as a `User`-source route with next hop
`VirtualAppliance`.

**Q8.** Yes — a route table is a standalone resource. It does
nothing until associated with a subnet; the association is a
subnet property. One table per subnet at most, and one table is
reusable across many subnets.

**Q9.** Every `az` resource still shows `Succeeded`, but the
effective route flips to state `Invalid` and traffic to the
UDR's prefix black-holes. The UDR itself stays in place.

**Q10.** A `0.0.0.0/0` UDR pointing at a firewall NVA (forced
tunneling) overrides the system internet route for the **whole
subnet** — every VM in it silently loses direct internet access,
including paths PaaS agents and extensions depend on. The answer
is always in the effective route table.

</details>
