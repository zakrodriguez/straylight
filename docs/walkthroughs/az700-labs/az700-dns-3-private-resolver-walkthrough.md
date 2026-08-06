# AZ-700 DNS Lab 3 — DNS Private Resolver

The dns module's first two labs resolved names *inside* Azure — private zones
linked to VNets, public zones on Azure name servers. Real hybrid networks need
resolution to cross the boundary **both ways**: on-prem clients resolving
Azure private zones, and Azure workloads resolving on-prem domains. The old
answer was a DNS-forwarder VM you ran and patched. **DNS Private Resolver** is
the managed replacement: a resolver with an **inbound endpoint** (a private IP
on-prem forwards *to*) and an **outbound endpoint** driving a **forwarding
ruleset** (which sends chosen domains *out* to on-prem DNS). This lab deploys
one, dissects the four pieces, and shows where the hybrid wiring plugs in.

Pairs with MS Learn: *Design and implement name resolution* — Azure DNS
Private Resolver (AZ-700 learning path).

> **Before you start**: this lab has **its own topology** — a small standalone
> VNet with the resolver, no gateway needed. Deploy it and add the CLI
> extension the resolver commands live in:
>
> ```bash
> az extension add --name dns-resolver --only-show-errors   # one-time
> azure/scripts/az700.sh deploy dns-private-resolver --no-wait
> azure/scripts/az700.sh watch dns-private-resolver          # ~5–10 min
> ```
>
> **Cost**: two resolver endpoints (~$0.07/hr each) + one B2ts_v2, **< $0.30**
> for a deploy-inspect-destroy sitting. **Teardown**: Step 6,
> `azure/scripts/az700.sh destroy dns-private-resolver`.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `dns-private-resolver` deployed (`watch` shows Succeeded) | the resolver, endpoints, and ruleset must exist to inspect |
| `dns-resolver` az CLI extension | the `az dns-resolver` command group ships in an extension |
| az CLI ≥ 2.60, logged in | every step is `az` from the host |
| Verification: VERIFIABLE (config-level; golden live-capture) | asserts resolver/endpoint/rule shape; the cross-tunnel answer is a runbook extension |

## Setup (one-time, idempotent)

Confirm the deployment finished:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-dns-private-resolver
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded
```

## Step 1 — The resolver and its VNet

A **DNS resolver** is a regional resource **bound to exactly one VNet** — it
resolves for that VNet and provides the endpoints. It is not a DNS server you
configure zones on; it is the plumbing that moves queries between Azure DNS and
external resolvers.

<!-- @verify host=lab step=resolver-shape expect=/Succeeded/ expect=/vnet-dnsr/ rc=0 -->
```bash
RG=rg-straylight-az700-dns-private-resolver
az dns-resolver show --resource-group $RG --name dnsr-straylight \
  --query "{state:provisioningState, vnet:virtualNetwork.id}" -o json
# Expected: provisioningState Succeeded, vnet ending in /vnet-dnsr
```

## Step 2 — The inbound endpoint (on-prem → Azure)

The **inbound endpoint** is a **private IP inside the resolver's VNet** that
listens for DNS queries. On-prem DNS (your `dc1`) gets a **conditional
forwarder** pointed at this IP for Azure private-zone domains — queries arrive
over the S2S tunnel and the resolver answers from Azure DNS (private zones
linked to the VNet, wire server `168.63.129.16` behind the scenes).

<!-- @verify host=lab step=inbound-endpoint expect=/10\.103\.4/ expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-dns-private-resolver
az dns-resolver inbound-endpoint list --resource-group $RG \
  --dns-resolver-name dnsr-straylight \
  --query "[].{name:name, state:provisioningState, ip:ipConfigurations[0].privateIpAddress}" -o json
# Expected: one endpoint, provisioningState Succeeded, privateIpAddress in
#           10.103.4.0/28 (snet-inbound) — the address on-prem forwards to
```

That private IP is the whole on-prem-to-Azure story: it is the single address
you hand your on-prem DNS as the forwarder target. It lives in `snet-inbound`,
a subnet **delegated to `Microsoft.Network/dnsResolvers`** — the resolver owns
that subnet; nothing else can share it.

## Step 3 — The outbound endpoint and the forwarding ruleset (Azure → on-prem)

The reverse direction is two resources. The **outbound endpoint** is the
resolver's egress, anchored in `snet-outbound`. A **forwarding ruleset**
attached to it holds the **rules**: "for domain X, forward to these DNS
servers." This is how an Azure workload resolves `straylight.lab` — the rule
sends that domain out to on-prem DNS over the tunnel.

<!-- @verify host=lab step=outbound-endpoint expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-dns-private-resolver
az dns-resolver outbound-endpoint list --resource-group $RG \
  --dns-resolver-name dnsr-straylight \
  --query "[].{name:name, state:provisioningState, subnet:subnet.id}" -o json
# Expected: one endpoint, provisioningState Succeeded, subnet ending in
#           /snet-outbound
```

Now the rule that uses it:

<!-- @verify host=lab step=forwarding-rule expect=/straylight.lab/ expect=/Enabled/ rc=0 -->
```bash
RG=rg-straylight-az700-dns-private-resolver
az dns-resolver forwarding-rule list --resource-group $RG \
  --ruleset-name fwrs-straylight \
  --query "[].{domain:domainName, state:forwardingRuleState, targets:targetDnsServers[].ipAddress}" -o json
# Expected: domainName straylight.lab. (trailing dot — FQDN form),
#           forwardingRuleState Enabled, targets ["192.168.56.10"]
```

The trailing dot on `straylight.lab.` is not a typo — forwarding rules match
**fully-qualified** domain names. The target `192.168.56.10` is on-prem `dc1`,
reachable only over the S2S tunnel — which is why the *live* answer is the
runbook extension below, not an asserted step here.

## Step 4 — Which VNets obey the ruleset

A ruleset only applies to VNets it is **linked** to — the link is what makes a
VNet's queries consult these forwarding rules. The resolver's own VNet is
linked at deploy:

<!-- @verify host=lab step=ruleset-link expect=/Succeeded/ expect=/vnet-dnsr/ rc=0 -->
```bash
RG=rg-straylight-az700-dns-private-resolver
az dns-resolver vnet-link list --resource-group $RG \
  --ruleset-name fwrs-straylight \
  --query "[].{name:name, state:provisioningState, vnet:virtualNetwork.id}" -o json
# Expected: one link, provisioningState Succeeded, vnet ending in /vnet-dnsr
```

Link the ruleset to more VNets (spokes, peered networks) and they all inherit
the same conditional-forwarding policy — centrally, with no per-VNet DNS server
setting. That central policy is the reason to choose the resolver over a
forwarder VM per VNet.

### Runbook: complete the hybrid loop (needs the tunnel)

Standalone, the pieces are proven by shape. To make resolution actually cross
the boundary, stand up `hybrid-vpn` (the S2S module) alongside this, then:

- **On-prem → Azure**: on `dc1`, add a **conditional forwarder** for your
  Azure private-zone domain (e.g. `privatelink.blob.core.windows.net` or a
  linked private zone) pointing at the **inbound endpoint IP** from Step 2.
  On-prem clients now resolve Azure private names over the tunnel.
- **Azure → on-prem**: the Step 3 rule already forwards `straylight.lab.` to
  `192.168.56.10`; with the tunnel up, `vm-dnsr1` resolving a
  `*.straylight.lab` name gets an answer from on-prem `dc1`.

Both directions depend on the resolver's VNet being reachable over the tunnel
(it is, once `hybrid-vpn` peers/routes the resolver VNet) — this is the
production shape the two labs combine into.

## Step 5 — (Optional) resolve from the workload VM

`vm-dnsr1` in `snet-workload` uses Azure-provided DNS, which the resolver
participates in. A control-plane probe confirms the VM is up and resolving
public names (the baseline before hybrid rules apply):

<!-- @verify host=lab step=vm-resolves expect=/RESOLVED/ rc=0 -->
```bash
RG=rg-straylight-az700-dns-private-resolver
az vm run-command invoke --resource-group $RG --name vm-dnsr1 \
  --command-id RunShellScript \
  --scripts "getent hosts mcr.microsoft.com >/dev/null && echo RESOLVED || echo FAILED" \
  --query "value[0].message" -o tsv
# Expected: output containing RESOLVED (the VM is up and its resolver answers a
#           public name — the baseline before hybrid forwarding rules apply)
```

## Step 6 — Teardown

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy dns-private-resolver
# Expected: "delete submitted for rg-straylight-az700-dns-private-resolver
#           (async)". Confirm the RG is gone later with: az700.sh sweep
```

## What you proved

- A **DNS Private Resolver** is bound to one VNet and provides two endpoints —
  the managed replacement for a DNS-forwarder VM.
- The **inbound endpoint** is a private IP on-prem forwards *to* (Azure private
  names resolve inbound over the tunnel); it lives in a subnet **delegated to
  `Microsoft.Network/dnsResolvers`**.
- The **outbound endpoint + forwarding ruleset** send chosen domains *out* to
  on-prem DNS; **rules** match FQDNs (trailing dot) and name target servers.
- A ruleset applies only to VNets it is **linked** to — central
  conditional-forwarding policy, no per-VNet DNS server.
- Inbound and outbound endpoints need **separate** delegated subnets; the
  live cross-boundary answer needs the S2S tunnel standing (the runbook loop).
