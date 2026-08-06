# AZ-700 LB Lab 2 — Application Gateway URL-Path Routing

Where the Load Balancer (Lab 1) moves TCP flows blind, **Application Gateway**
reads the HTTP request and routes on it — by **URL path** and by **host
header**. It is the **Layer-7**, regional application delivery controller, and
the thing the exam wants you to reach for whenever routing depends on *what the
request is asking for*, not just *which port*. This lab deploys a Standard_v2
gateway with a **URL-path map** — `/images/*` to one backend pool, everything
else to another — and proves the routing with `curl`.

Pairs with MS Learn: *Design and implement application delivery* — Azure
Application Gateway (AZ-700 learning path).

> **Part A — deploy (this takes ~15–20 minutes)**. Application Gateway is a
> long-running resource, so — like the VPN gateway — it is deployed by the
> script, never inside a lab step. Start it and gate on it:
>
> ```bash
> azure/scripts/az700.sh deploy appgw --no-wait
> azure/scripts/az700.sh watch appgw        # polls until Succeeded (~15-20 min)
> ```
>
> **Cost**: AppGW Standard_v2 meters at **~$0.25/hr** (plus capacity units)
> from creation, provisioning window included; with the two B2ts_v2 backends a
> sitting is **< $0.60**. **Teardown when done**: `azure/scripts/az700.sh
> destroy appgw` (Step 6). Never leave a gateway up overnight.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `azure/scripts/az700.sh deploy appgw` provisioned (`watch` shows Succeeded) | the gateway and its two backends must exist to inspect |
| az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `curl` on the host | the routing proof curls the gateway with and without the path |
| Verification: VERIFIABLE (walkverify golden, live-capture) | config projections + a live path-routing `curl` proof |

## Part B — the routing, dissected

### Setup (one-time, idempotent)

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-appgw
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded
```

### Step 1 — The SKU: Standard_v2, and why v2

<!-- @verify host=lab step=agw-sku expect=/Standard_v2/ rc=0 -->
```bash
RG=rg-straylight-az700-appgw
az network application-gateway show --resource-group $RG --name agw-straylight \
  --query "{sku:sku.name, tier:sku.tier, capacity:sku.capacity}" -o json
# Expected: sku/tier Standard_v2, capacity 1
```

**v2** (Standard_v2 / WAF_v2) is the current generation: autoscaling, zone
redundancy, static VIP, header rewrite. **v1** is legacy. WAF (Lab 3) rides the
**WAF_v2** tier — same gateway, WAF turned on.

### Step 2 — The listener accepts the request

An **HTTP listener** binds a frontend IP + port + protocol; it is what receives
the client request before any routing decision. This one listens on the public
frontend, port 80, HTTP.

<!-- @verify host=lab step=listener expect=/Http/ rc=0 -->
```bash
RG=rg-straylight-az700-appgw
az network application-gateway http-listener list --resource-group $RG \
  --gateway-name agw-straylight \
  --query "[].{name:name, protocol:protocol}" -o json
# Expected: listener-http, protocol Http
```

### Step 3 — Two backend pools to choose between

Routing is only interesting if there is more than one destination. This gateway
has two backend pools — `pool-default` and `pool-images` — each holding one of
the backend VMs.

<!-- @verify host=lab step=backend-pools expect=/pool-default/ expect=/pool-images/ rc=0 -->
```bash
RG=rg-straylight-az700-appgw
az network application-gateway address-pool list --resource-group $RG \
  --gateway-name agw-straylight --query "[].name" -o json
# Expected: pool-default and pool-images
```

### Step 4 — The URL-path map is the routing brain

The **URL-path map** is where Layer-7 routing lives: a default pool for
unmatched requests, plus path rules that send matching paths elsewhere. Here
`/images/*` goes to `pool-images`; everything else falls through to
`pool-default`.

<!-- @verify host=lab step=path-map expect=/images/ expect=/pool-images/ rc=0 -->
```bash
RG=rg-straylight-az700-appgw
az network application-gateway url-path-map show --resource-group $RG \
  --gateway-name agw-straylight --name pathmap \
  --query "{default:defaultBackendAddressPool.id, rules:pathRules[].{name:name, paths:paths, pool:backendAddressPool.id}}" -o json
# Expected: a path rule 'images' matching /images/* -> a pool id ending pool-images;
#           default pool id ending pool-default
```

### Step 5 — Prove the path routing

Read the gateway's public IP, then curl it two ways. A bare request lands on
`pool-default` (`vm-appgw1`); an `/images/` request is steered to `pool-images`
(`vm-appgw2`). Same gateway, same listener — the **path** chose the pool.

<!-- @verify host=lab step=route-proof expect=/vm-appgw1/ expect=/vm-appgw2/ rc=0 -->
```bash
RG=rg-straylight-az700-appgw
GIP=$(az network public-ip show --resource-group $RG --name agwpip-straylight \
  --query ipAddress -o tsv)
# wait for the backends to register healthy behind the gateway
for i in $(seq 1 40); do
  out=$(curl -s --max-time 3 "http://$GIP/" 2>/dev/null)
  case "$out" in vm-appgw*) break;; esac
  sleep 5
done
echo "default path -> $(curl -s --max-time 3 http://$GIP/)"
echo "/images/ path -> $(curl -s --max-time 3 http://$GIP/images/)"
# Expected: default path -> vm-appgw1, /images/ path -> vm-appgw2
```

### Step 6 — Teardown

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy appgw
# Expected: "delete submitted for rg-straylight-az700-appgw (async)".
#           Confirm the RG is gone later with: az700.sh sweep
```

## What you proved

- Application Gateway is **Layer 7**: it terminates the HTTP request on a
  **listener**, then routes on content — **URL path** (this lab) or **host
  header** — where a Layer-4 load balancer only sees ports.
- **Standard_v2** is the current tier (autoscale, zonal, static VIP); **WAF_v2**
  is the same gateway with the firewall on (Lab 3).
- The **URL-path map** is the routing brain: a default pool plus path rules;
  `/images/*` reached a different backend than `/`, proven by `curl`.
- Long-running gateways are deployed by the topology and gated with
  `az700.sh watch` — never provisioned inside a lab step.
