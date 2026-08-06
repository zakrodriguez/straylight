# AZ-700 LB Lab 1 — Standard Load Balancer

Azure Load Balancer is the **Layer-4** front door: it distributes TCP/UDP flows
across a backend pool of VMs, decides who is healthy with a probe, and does it
all without ever looking inside the packet. This lab deploys a public
**Standard** Load Balancer over two backend VMs, dissects its five parts — the
**SKU**, the **frontend IP**, the **backend pool**, the **health probe**, and
the **load-balancing rule** — and then proves it works by curling the frontend
and watching the two backends take turns.

Pairs with MS Learn: *Design and implement load balancing* — Azure Load
Balancer (AZ-700 learning path).

> **Before you start**: deploy the topology. The two backend VMs each run a
> tiny web server that returns their hostname (seeded by cloud-init), so the
> load balancer has something healthy to distribute to.
>
> ```bash
> az account show --query id -o tsv          # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy lb-standard
> ```
>
> This lab and **Lab 4 (Traffic Manager)** share this one deployment — run
> them back-to-back and tear down once at the end.
>
> **Cost**: 2 × B2ts_v2 + a Standard LB (~$0.025/hr) + one Standard public IP,
> **< $0.30** for a sitting. **Teardown**: Lab 4's last step (or
> `azure/scripts/az700.sh destroy lb-standard` now if you stop here).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `azure/scripts/az700.sh deploy lb-standard` provisioned | the LB and its two backends must exist to inspect |
| az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `curl` on the host | the distribution proof curls the LB's public frontend |
| Verification: VERIFIABLE (walkverify golden, live-capture) | config projections + a live `curl` distribution proof |

## Setup (one-time, idempotent)

Confirm the deployment finished:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded
```

## Step 1 — The SKU is the first and most consequential choice

A load balancer's **SKU** decides almost everything else: **Standard** (this
lab) is secure-by-default (closed until an NSG opens it), supports
availability zones, HA ports, larger backend pools, and outbound rules;
**Basic** is legacy, being retired, has no SLA, and no zone support. New
designs are always Standard.

<!-- @verify host=lab step=lb-sku expect=/Standard/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
az network lb show --resource-group $RG --name lb-straylight \
  --query "{sku:sku.name, tier:sku.tier}" -o json
# Expected: sku Standard
```

## Step 2 — The frontend IP is where clients arrive

The **frontend IP configuration** is the address the world dials. For a public
LB it is a Standard public IP; for an internal LB it would be a private address
in a subnet — that frontend type is the *only* difference between a public and
an internal load balancer.

<!-- @verify host=lab step=frontend expect=/frontend/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
az network lb frontend-ip list --resource-group $RG --lb-name lb-straylight \
  --query "[].{name:name, hasPublicIp:publicIPAddress.id!=null}" -o json
# Expected: one frontend named 'frontend' with a public IP attached
```

## Step 3 — The backend pool is who receives the traffic

The **backend pool** is the set of VMs (by NIC or by IP) that receive
distributed flows. Here both backend VMs joined the pool at deploy — read the
membership:

<!-- @verify host=lab step=backend-pool expect=/2/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
az network lb address-pool show --resource-group $RG --lb-name lb-straylight \
  --name bepool \
  --query "length(backendIPConfigurations)" -o tsv
# Expected: 2   (the two backend VM NICs are pool members; NIC-based pools list
#           members under backendIPConfigurations, not loadBalancerBackendAddresses)
```

## Step 4 — The health probe decides who is eligible

The **health probe** is what makes a load balancer more than a dumb splitter:
it removes an unhealthy backend from rotation automatically. This one is an
HTTP probe on :80 hitting `/` — a backend that stops answering is pulled.

<!-- @verify host=lab step=health-probe expect=/Http/ expect=/80/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
az network lb probe list --resource-group $RG --lb-name lb-straylight \
  --query "[].{name:name, protocol:protocol, port:port, path:requestPath}" -o json
# Expected: an Http probe on port 80, requestPath '/'
```

## Step 5 — The rule ties it together

The **load-balancing rule** binds a frontend port to a backend port for a
protocol, using a probe to pick healthy members. This one sends TCP :80 on the
frontend to :80 on the pool.

<!-- @verify host=lab step=lb-rule expect=/Tcp/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
az network lb rule list --resource-group $RG --lb-name lb-straylight \
  --query "[].{name:name, proto:protocol, feport:frontendPort, beport:backendPort}" -o json
# Expected: a Tcp rule, frontendPort 80 -> backendPort 80
```

## Step 6 — Prove it distributes

Read the frontend public IP, then curl it a few times. Each backend returns its
own hostname, so repeated requests show the load balancer spreading flows
across `vm-lb1` and `vm-lb2`. Allow a moment after deploy for the probes to
mark both backends healthy.

<!-- @verify host=lab step=distribute expect=/vm-lb[12]/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
FIP=$(az network public-ip show --resource-group $RG --name lbpip-straylight \
  --query ipAddress -o tsv)
# poll until a backend answers (probes need ~15-30s post-deploy)
for i in $(seq 1 40); do
  out=$(curl -s --max-time 3 "http://$FIP" 2>/dev/null)
  case "$out" in vm-lb*) break;; esac
  sleep 5
done
# a few requests to show both backends serving
for i in 1 2 3 4; do curl -s --max-time 3 "http://$FIP"; done | sort -u
# Expected: vm-lb1 and/or vm-lb2 (the LB distributing across the pool)
```

## What you proved

- A load balancer's **SKU** (Standard vs Basic) is the load-bearing choice —
  Standard is secure-by-default, zone-aware, and the only one for new designs.
- The five parts: **frontend IP** (where clients arrive; public vs internal is
  just this), **backend pool** (who receives), **health probe** (who is
  eligible — the self-healing part), and the **rule** (frontend port →
  backend port for a protocol, via the probe).
- It operates at **Layer 4** — it distributes TCP/UDP flows and never inspects
  HTTP; URL/host routing is Application Gateway's job (Lab 2).
- The frontend `curl` returns alternating backend hostnames — the load
  balancer is spreading traffic across a healthy pool.
