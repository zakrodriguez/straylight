# AZ-700 VNet Lab 4 — Explicit Outbound with NAT Gateway

Azure VMs used to get internet access for free: an implicit, shared SNAT
address that nobody configured, nobody owned, and nobody could depend on.
That behavior is retired for new subnets, and the exam expects you to pick
an explicit outbound method instead. This lab starts with a VM that has no
outbound path at all, proves it, then builds the preferred fix — a NAT
gateway — and shows the VM's egress moving to an address you allocated
deliberately.

Pairs with MS Learn: *Introduction to Azure virtual networks* — design
outbound connectivity with Virtual Network NAT (AZ-700 learning path, Design
and implement core networking infrastructure).

> **Before you start**: no Straylight VMs are needed (azure-only lab). You
> need an Azure subscription with az CLI logged in and this lab's own
> topology deployed — Lab 4 does **not** share the hub-spoke estate used by
> Labs 1–3:
>
> ```bash
> az account show --query id -o tsv          # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy nat-gateway  # vnet-nat + 1 B2ts_v2 VM, no outbound (~2 min)
> ```
>
> **Cost**: < $0.30 for the session (one B2ts_v2 VM, the NAT gateway at
> ~$0.045/hr, and one Standard public IP — all torn down the same day).
> **Teardown when done**: `azure/scripts/az700.sh destroy nat-gateway`
> (Step 6 — this lab stands alone, so never skip it).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Azure subscription + az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `azure/scripts/az700.sh deploy nat-gateway` run this session | provides the RG, vnet-nat, and vm-nat1 with no outbound path |
| Azure spend this session: < $0.30 | one B2ts_v2 + NAT gateway + public IP; nothing hourly-expensive |
| Teardown: `az700.sh destroy nat-gateway` (Step 6) | same-day teardown is the track's budget model |
| Verification: VERIFIABLE (walkverify golden) | pure az CLI with `-o tsv` projections |

## Setup (one-time, idempotent)

Every code block in this lab is self-contained — each one names the resource
group itself, so any block can be re-run standalone. Confirm the deployment
finished:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-nat-gateway
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded   (anything else: run azure/scripts/az700.sh deploy nat-gateway)
```

## Step 1 — Read the subnet's outbound posture

The deploy created `vnet-nat` (10.103.1.0/24) with a single subnet,
`snet-workload`, spanning the whole /24, and one VM in it — `vm-nat1`, a
B2ts_v2 with **no public IP**. The template also set one property you should learn
to look for:

<!-- @verify host=lab step=outbound-posture expect=/false/ rc=0 -->
```bash
RG=rg-straylight-az700-nat-gateway
az network vnet subnet show --resource-group $RG --vnet-name vnet-nat \
  --name snet-workload --query defaultOutboundAccess -o tsv
# Expected: false
```

`defaultOutboundAccess: false` switches off Azure's **implicit default
outbound SNAT** — the shared, unowned public address VMs historically fell
back to when nothing else provided a path out. Microsoft announced its
retirement for newly created subnets in September 2025; new designs must
not rely on it. The exam expects you to name an *explicit* outbound method
and pick between the three:

- **NAT gateway** — the recommended default for subnet-level outbound.
- **Load-balancer outbound rules** — when a Standard LB already fronts the
  workload and you want one resource doing both directions.
- **Instance-level public IP** — one VM, inbound needed anyway; the address
  rides on the NIC.

Right now `snet-workload` has none of the three, so `vm-nat1` should be
unable to reach anything. Prove that before fixing it.

## Step 2 — Prove there is no outbound path

Ask the VM to fetch its own public address from api.ipify.org. With no
outbound method the TCP connection can never complete, `curl` times out,
and the fallback `echo` fires:

<!-- @verify host=lab step=no-outbound expect=/NO-OUTBOUND/ rc=0 -->
```bash
RG=rg-straylight-az700-nat-gateway
az vm run-command invoke --resource-group $RG --name vm-nat1 \
  --command-id RunShellScript \
  --scripts "curl -m 8 -sS https://api.ipify.org || echo NO-OUTBOUND" \
  --query "value[0].message" -o tsv
# Expected: output containing NO-OUTBOUND (allow ~30-60s; run-command is slow)
```

Pause on the trick hiding in this step: how did the command reach a VM with
no connectivity at all? `az vm run-command` travels through the **Azure
control plane** to the VM agent — it never touches the VNet's data plane.
That is exactly why it still works here, and why the exam likes it as a
distractor: run-command succeeding proves nothing about network
reachability, NSGs, or routes.

## Step 3 — Create the NAT gateway

A NAT gateway needs a frontend to SNAT onto. Allocate one first:

<!-- @verify host=lab step=create-pip expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-nat-gateway
az network public-ip create --resource-group $RG --name pip-natgw \
  --sku Standard --query publicIp.provisioningState -o tsv
# Expected: Succeeded
```

Only **Standard SKU** public IPs (or public IP *prefixes*) can attach to a
NAT gateway — Basic is not accepted. A NAT gateway takes up to **16**
addresses, and each address contributes ~64,000 SNAT ports to the pool.
When an exam question says "SNAT port exhaustion" the first lever is
*add addresses to the NAT gateway* (or attach a prefix), not resize VMs.

Now the gateway itself:

<!-- @verify host=lab step=create-natgw expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-nat-gateway
az network nat gateway create --resource-group $RG --name natgw-lab \
  --public-ip-addresses pip-natgw --idle-timeout 4 \
  --query provisioningState -o tsv
# Expected: Succeeded
```

Two properties worth memorizing. **Idle timeout** is 4–120 minutes (4 is
the default and the right answer unless long-lived quiet TCP flows are
called out). And a NAT gateway is **outbound-only**: it never accepts an
unsolicited inbound flow, so it is not a security hole you need an NSG for
— return traffic on established flows is the only thing that comes back in.

## Step 4 — Attach it to the subnet

The gateway exists but routes nothing until a subnet is associated with it:

<!-- @verify host=lab step=attach-subnet expect=/natgw-lab/ rc=0 -->
```bash
RG=rg-straylight-az700-nat-gateway
az network vnet subnet update --resource-group $RG --vnet-name vnet-nat \
  --name snet-workload --nat-gateway natgw-lab \
  --query natGateway.id -o tsv
# Expected: a resource ID ending in /natGateways/natgw-lab
```

Association rules, exactly as the exam tests them: the link is
**per-subnet**. A subnet can have at most **one** NAT gateway; one NAT
gateway can serve **many** subnets of the same VNet (it cannot span VNets).
And once attached, the NAT gateway **takes precedence over every other
outbound method** on that subnet — load-balancer outbound rules and
instance-level public IPs on member VMs are bypassed for outbound flows.

## Step 5 — Egress now works, from the address you allocated

Repeat the Step 2 probe. This time `curl` succeeds, and the address
api.ipify.org reports must be `pip-natgw`'s — the `grep` at the end
compares them, and its exit code is the assertion:

<!-- @verify host=lab step=egress-ip expect=/<PUBIP>|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/ rc=0 -->
```bash
RG=rg-straylight-az700-nat-gateway
NATIP=$(az network public-ip show --resource-group $RG --name pip-natgw \
  --query ipAddress -o tsv)
az vm run-command invoke --resource-group $RG --name vm-nat1 \
  --command-id RunShellScript \
  --scripts "curl -m 20 -sS https://api.ipify.org" \
  --query "value[0].message" -o tsv | grep -F "$NATIP"
# Expected: the run-command output line containing the NAT gateway's public
# address — grep exits 0 only if the VM's egress IP equals pip-natgw's IP
```

The VM itself still has no public IP; nothing about the VM changed. The
subnet's outbound method changed, and every present and future VM in
`snet-workload` inherits it — that per-subnet, zero-per-VM-config behavior
is the core of the "design outbound connectivity" learning objective. (In
the committed golden the `pubip` normalizer masks the real address as
`<PUBIP>`; the grep's exit code carried the equality check at capture
time.)

## Step 6 — Teardown

This lab's topology is its own — nothing else uses it, so tear it down now:

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy nat-gateway
# Expected: "delete submitted for rg-straylight-az700-nat-gateway (async)"
```

The resource group is the state: VNet, VM, NAT gateway, and public IP all
die with it. Confirm later with `azure/scripts/az700.sh list` or
`az group list --tag track=az700 -o table`.

Before you close the terminal, fix the decision rule this lab demonstrated.
When a question asks how VMs should reach the internet: **default outbound
is retired — never the answer for new designs**; an instance-level public
IP is for one machine that needs inbound anyway; LB outbound rules fit only
when a Standard LB already fronts the pool. Everything else — many VMs,
outbound-only, SNAT scale — is **NAT gateway**.

## What you proved

- A subnet with `defaultOutboundAccess: false` and no explicit outbound
  method leaves its VMs with no internet path — and `az vm run-command`
  still reaches them, because it rides the control plane, not the network.
- A NAT gateway is built from Standard SKU public IPs (up to 16, ~64k SNAT
  ports each) and is outbound-only, with a 4–120 minute idle timeout.
- Associating it is per-subnet, one gateway per subnet, many subnets per
  gateway — and it overrides every other outbound method on the subnet.
- After association the VM egresses from the NAT gateway's address with no
  per-VM configuration — the exam's preferred explicit outbound design.
