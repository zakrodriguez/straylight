# Quiz — AZ-700 VNet Lab 1: Address Space, Subnets, and Reserved Names

**Lab:** `az700-vnet-1-address-space-subnets-walkthrough.md`
**Format:** 10 questions on subnet arithmetic, the five reserved
addresses, reserved subnet names and their size floors, overlap
failures, and the `az network vnet` command set.
**Suggested time:** 10–15 minutes.

---

**Q1.** In one sentence each: what does a VNet's **address space**
represent, and what do its **subnets** do with it?

(short answer)

---

**Q2.** Match each reserved subnet name to its rule:

| Reserved name | Rule |
|---|---|
| `GatewaySubnet` | __________ |
| `AzureBastionSubnet` | __________ |
| `RouteServerSubnet` | __________ |

(choices: minimum /26, enforced at deploy time; minimum /27;
hard minimum /29 with /27 recommended, and it must not carry an NSG)

---

**Q3.** Azure reserves five addresses in every subnet. Name all
five and state what each is for.

(short answer)

---

**Q4.** Exam arithmetic — *usable addresses = 2^(32−n) − 5*.
Fill in the table, then name the smallest prefix that fits 25 VMs:

| Prefix | Usable addresses |
|---|---|
| /29 | __________ |
| /28 | __________ |
| /26 | __________ |
| /24 | __________ |

(four counts + one prefix)

---

**Q5.** `snet-a` is `10.103.0.0/26`. Predict the output of each
command and give the one-line reason:

```bash
az network vnet check-ip-address --resource-group $RG --name vnet-lab1 \
  --ip-address 10.103.0.1 --query available -o tsv

az network vnet check-ip-address --resource-group $RG --name vnet-lab1 \
  --ip-address 10.103.0.10 --query available -o tsv
```

(predict the output)

---

**Q6.** `snet-a` occupies `10.103.0.0/26`. Predict what happens
when this runs, and name the error code the exam tests:

```bash
az network vnet subnet create --resource-group $RG --vnet-name vnet-lab1 \
  --name snet-oops --address-prefixes 10.103.0.32/27 -o table
```

(predict the output)

---

**Q7.** Two VNets in the same subscription are created with
overlapping address spaces. Does the second creation fail? What is
the lasting consequence, and how does the track's `10.100.0.0/14`
plan avoid it?

(short answer)

---

**Q8.** Can you add a subnet to a VNet that already has running
VMs? State the two constraints the new prefix must satisfy.

(short answer)

---

**Q9.** Fill in the two missing flags:

```bash
az network vnet create --resource-group $RG --name vnet-lab1 \
  --__________ 10.103.0.0/24 \
  --subnet-name snet-a --__________ 10.103.0.0/26
```

(two flag names)

---

**Q10.** A colleague deploys a VPN gateway and Azure refuses to
place it in their subnet named `gw-subnet`. What is wrong, and
what is the NSG rule for the corrected subnet?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** The address space is what the VNet owns — the prefix pool
all its subnets must come from. Subnets carve that space up; each
subnet's prefix must fit inside the space and overlap no other
subnet.

**Q2.**
- `GatewaySubnet` → hard minimum /29 with /27 recommended, and it
  must not carry an NSG
- `AzureBastionSubnet` → minimum /26, enforced at deploy time
- `RouteServerSubnet` → minimum /27

**Q3.** The network address, the last (broadcast) address, `.1`
(the subnet's default gateway), and `.2` and `.3` (Azure DNS
mapping). Five total — the first assignable host address is `.4`.

**Q4.**
- /29 → 3
- /28 → 11
- /26 → 59
- /24 → 251

25 VMs need 25 + 5 = 30 addresses, so the smallest fit is a /27
(32 addresses, 27 usable). Add the five before you size.

**Q5.** First command: `false` — `.1` is the subnet's default
gateway, one of the five reserved addresses. Second command:
`true` — `.10` is an ordinary assignable address (assignable
addresses start at `.4`). (az prints tsv booleans lowercase.)

**Q6.** The creation fails. `10.103.0.0/26` covers `.0`–`.63` and
the new /27 claims `.32`–`.63`, so the ranges collide. The error
code is `NetcfgSubnetRangesOverlap`; the exact message text shifts
across az versions, so read the code, not the prose.

**Q7.** The second creation succeeds — two VNets *may* hold
overlapping address spaces. The lasting consequence: those VNets
can never be peered or connected. The track avoids it by
pre-planning every VNet under one `10.100.0.0/14` pool so nothing
collides.

**Q8.** Yes — subnets can be added to a live VNet at any time.
The prefix must (1) fit inside the VNet's address space and
(2) overlap no existing subnet.

**Q9.** `--address-prefixes` (the VNet's space) and
`--subnet-prefixes` (the initial subnet's prefix).

**Q10.** `GatewaySubnet` is a reserved *name*, not a convention —
a VPN or ExpressRoute gateway deploys only into a subnet named
exactly `GatewaySubnet`. After renaming, the subnet must not have
an NSG attached.

</details>
