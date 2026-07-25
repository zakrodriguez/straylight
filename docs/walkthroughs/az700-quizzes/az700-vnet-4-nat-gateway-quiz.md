# Quiz — AZ-700 VNet Lab 4: Explicit Outbound with NAT Gateway

**Lab:** `az700-vnet-4-nat-gateway-walkthrough.md`
**Format:** 10 questions on the default-outbound retirement,
explicit outbound methods, NAT gateway SKU and SNAT facts, idle
timeout, association rules, and outbound precedence.
**Suggested time:** 10–15 minutes.

---

**Q1.** What does `defaultOutboundAccess: false` on a subnet
switch off, and why must new designs not rely on that behavior?

(short answer)

---

**Q2.** Match each scenario to its outbound method:

| Scenario | Outbound method |
|---|---|
| Many VMs, outbound-only, SNAT scale | __________ |
| A Standard LB already fronts the pool | __________ |
| One VM that needs inbound anyway | __________ |
| A newly created subnet with nothing configured | __________ |

(choices: NAT gateway; load-balancer outbound rules;
instance-level public IP; no outbound path — implicit default
outbound is retired for new subnets)

---

**Q3.** The subnet has `defaultOutboundAccess: false` and no
explicit outbound method. Predict what the message contains, and
why:

```bash
az vm run-command invoke --resource-group $RG --name vm-nat1 \
  --command-id RunShellScript \
  --scripts "curl -m 8 -sS https://api.ipify.org || echo NO-OUTBOUND" \
  --query "value[0].message" -o tsv
```

(predict the output)

---

**Q4.** How did the command in Q3 reach a VM with no network
path at all, and what does a successful run-command therefore
prove about network reachability?

(short answer)

---

**Q5.** Fill in the two blanks — the SKU a NAT gateway accepts
and the default idle timeout in minutes:

```bash
az network public-ip create --resource-group $RG --name pip-natgw \
  --sku __________ --query publicIp.provisioningState -o tsv
az network nat gateway create --resource-group $RG --name natgw-lab \
  --public-ip-addresses pip-natgw --idle-timeout __________ \
  --query provisioningState -o tsv
```

(SKU + number)

---

**Q6.** How many public IP addresses can a NAT gateway take, how
many SNAT ports does each address contribute, and what is the
first lever when an exam question says "SNAT port exhaustion"?

(short answer)

---

**Q7.** What is the allowed idle-timeout range, and what workload
detail in a question justifies raising it above the default?

(short answer)

---

**Q8.** Is a NAT gateway a security hole that needs an NSG to
block inbound connections? Explain what traffic can come back in.

(short answer)

---

**Q9.** State the association rules: what the NAT gateway link
attaches to, how many gateways a subnet can have, how many
subnets a gateway can serve (and across what boundary it cannot
reach), and what happens to load-balancer outbound rules and
instance-level public IPs on member VMs once it is attached.

(short answer)

---

**Q10.** After `natgw-lab` is associated with `snet-workload`,
`vm-nat1`'s curl succeeds. What changed on the VM itself, whose
address does api.ipify.org report, and which VMs in the subnet
inherit this behavior?

(short answer)

---

## Answer key

<details>
<summary>Click to expand</summary>

**Q1.** It switches off Azure's implicit default outbound SNAT —
the shared, unowned public address VMs historically fell back to
when nothing else provided a path out. Microsoft announced its
retirement for newly created subnets in September 2025, so new
designs must name an explicit outbound method instead.

**Q2.**
- Many VMs, outbound-only, SNAT scale → NAT gateway
- A Standard LB already fronts the pool → load-balancer outbound
  rules
- One VM that needs inbound anyway → instance-level public IP
- A newly created subnet with nothing configured → no outbound
  path — implicit default outbound is retired for new subnets

**Q3.** The message contains `NO-OUTBOUND`. With no outbound
method the TCP connection to api.ipify.org can never complete,
`curl` times out at 8 seconds, and the fallback `echo` fires.

**Q4.** `az vm run-command` travels through the Azure control
plane to the VM agent — it never touches the VNet's data plane.
A successful run-command therefore proves nothing about network
reachability, NSGs, or routes; the exam uses it as a distractor.

**Q5.** `--sku Standard` and `--idle-timeout 4`. Only Standard
SKU public IPs (or public IP prefixes) can attach to a NAT
gateway — Basic is not accepted — and 4 minutes is the default
idle timeout.

**Q6.** Up to 16 addresses, each contributing ~64,000 SNAT ports
to the pool. The first lever for SNAT port exhaustion is adding
addresses to the NAT gateway (or attaching a prefix) — not
resizing VMs.

**Q7.** 4–120 minutes. 4 is the default and the right answer
unless the question calls out long-lived quiet TCP flows.

**Q8.** No. A NAT gateway is outbound-only: it never accepts an
unsolicited inbound flow, so it is not a security hole that needs
an NSG. Return traffic on established flows is the only thing
that comes back in.

**Q9.** The link is per-subnet. A subnet can have at most one NAT
gateway; one NAT gateway can serve many subnets of the same VNet
but cannot span VNets. Once attached, the NAT gateway takes
precedence over every other outbound method on that subnet —
load-balancer outbound rules and instance-level public IPs on
member VMs are bypassed for outbound flows.

**Q10.** Nothing changed on the VM — it still has no public IP.
api.ipify.org reports `pip-natgw`'s address, because the subnet's
outbound method changed. Every present and future VM in
`snet-workload` inherits it with zero per-VM configuration — the
exam's preferred explicit outbound design.

</details>
