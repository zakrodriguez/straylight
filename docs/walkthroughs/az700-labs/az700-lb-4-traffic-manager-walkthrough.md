# AZ-700 LB Lab 4 — Traffic Manager

Load Balancer and Application Gateway are **regional** — they sit in front of
backends in one region. **Traffic Manager** is **global**, and it works
entirely differently: it is a **DNS-based** director. It never sees a packet.
A client resolving your Traffic Manager name gets back the DNS answer for
whichever endpoint the **routing method** chose; the client then connects to
that endpoint directly. This lab builds a profile over the Lab 1 load balancer
plus a second endpoint, reads the routing and health model, and resolves the
`*.trafficmanager.net` name to watch it choose.

Pairs with MS Learn: *Design and implement application delivery* — Azure
Traffic Manager (AZ-700 learning path).

> **Before you start**: this lab **reuses the `lb-standard` deployment** from
> Lab 1 (its public load balancer becomes a Traffic Manager endpoint). If it is
> still up from Lab 1, continue straight in; if not:
>
> ```bash
> azure/scripts/az700.sh deploy lb-standard
> ```
>
> **Cost**: a Traffic Manager profile is **~$0.54/month** prorated plus a tiny
> per-query charge — **effectively free** for a sitting. **Teardown**: Step 6
> tears down the whole `lb-standard` deployment (the profile lives in that
> resource group and dies with it).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `azure/scripts/az700.sh deploy lb-standard` provisioned | the load balancer's public IP becomes a Traffic Manager endpoint |
| az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `nslookup` (or `dig`) on the host | the resolution proof queries the `*.trafficmanager.net` name |
| Verification: VERIFIABLE (walkverify golden, live-capture) | profile config projections + a live DNS resolution proof |

## Setup (one-time, idempotent)

Confirm the load balancer is there and read its public IP — that address is the
first endpoint:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded
```

## Step 1 — Create the profile (the routing method is the whole game)

A Traffic Manager **profile** has one **routing method** that decides which
endpoint a query returns. Create one with **Priority** routing (an ordered
failover list) and an HTTP health monitor on :80. The DNS name must be globally
unique, so a short random suffix is added and remembered for later steps.

<!-- @verify host=lab step=create-profile expect=/Enabled/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
TM="tmstraylight$(openssl rand -hex 3)"
echo "$TM" > /tmp/tm-name
# Create the profile (its create response doesn't project status cleanly), then
# read the status/method back with `show`.
az network traffic-manager profile create --resource-group $RG --name "$TM" \
  --routing-method Priority --unique-dns-name "$TM" \
  --ttl 30 --protocol HTTP --port 80 --path "/" -o none
az network traffic-manager profile show --resource-group $RG --name "$TM" \
  --query "{status:profileStatus, method:trafficRoutingMethod}" -o tsv
# Expected: Enabled  Priority
```

The five routing methods, at a glance: **Priority** (failover order),
**Weighted** (round-robin by weight), **Performance** (lowest latency to the
client), **Geographic** (by the client's region), and **MultiValue** (return
several healthy endpoints at once). The exam tests picking the right one.

## Step 2 — Add the load balancer as the primary endpoint

Endpoints are what the profile chooses between. Add the Lab 1 load balancer's
public IP as an **external** endpoint at priority 1:

<!-- @verify host=lab step=add-primary expect=/Enabled/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
TM=$(cat /tmp/tm-name)
FIP=$(az network public-ip show --resource-group $RG --name lbpip-straylight \
  --query ipAddress -o tsv)
az network traffic-manager endpoint create --resource-group $RG \
  --profile-name "$TM" --name primary --type externalEndpoints \
  --target "$FIP" --endpoint-status Enabled --priority 1 \
  --query "{name:name, status:endpointStatus, target:target}" -o tsv
# Expected: primary  Enabled  <the LB public IP>
```

## Step 3 — Add a second endpoint (the failover target)

Priority routing needs somewhere to fail over to. Add a second external
endpoint at priority 2 (a documentation IP stands in for a second region):

<!-- @verify host=lab step=add-secondary expect=/Enabled/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
TM=$(cat /tmp/tm-name)
az network traffic-manager endpoint create --resource-group $RG \
  --profile-name "$TM" --name secondary --type externalEndpoints \
  --target 198.51.100.10 --endpoint-status Enabled --priority 2 \
  --query "{name:name, status:endpointStatus, priority:priority}" -o tsv
# Expected: secondary  Enabled  2
```

## Step 4 — Read the routing and health model

The profile's behaviour is its routing method plus its monitor settings — read
them together:

<!-- @verify host=lab step=profile-config expect=/Priority/ expect=/HTTP/ rc=0 -->
```bash
RG=rg-straylight-az700-lb-standard
TM=$(cat /tmp/tm-name)
az network traffic-manager profile show --resource-group $RG --name "$TM" \
  --query "{method:trafficRoutingMethod, monitorProto:monitorConfig.protocol, monitorPort:monitorConfig.port, fqdn:dnsConfig.fqdn, endpoints:length(endpoints)}" -o json
# Expected: method Priority, monitorProto HTTP, monitorPort 80,
#           fqdn <name>.trafficmanager.net, endpoints 2
```

## Step 5 — Resolve the name and watch it choose

This is the point of Traffic Manager: resolving the profile's FQDN returns the
address of the endpoint the routing method picked. With Priority routing and
the primary (the load balancer) healthy, the name resolves to the load
balancer's IP.

<!-- @verify host=lab step=resolve expect=/Address/ rc=0 -->
```bash
TM=$(cat /tmp/tm-name)
FQDN="${TM}.trafficmanager.net"
# TM answers with the chosen endpoint; allow a few seconds for the record
for i in $(seq 1 12); do
  nslookup "$FQDN" 2>/dev/null | grep -A2 "Name:" && break
  sleep 5
done
nslookup "$FQDN" 2>/dev/null | grep -E "Name:|Address"
# Expected: the FQDN resolving to the primary endpoint (the LB public IP) —
#           Traffic Manager returned the priority-1 healthy endpoint by DNS
```

## Step 6 — Teardown

This removes the whole `lb-standard` deployment, and the Traffic Manager
profile with it (it lives in that resource group).

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
rm -f /tmp/tm-name
azure/scripts/az700.sh destroy lb-standard
# Expected: "delete submitted for rg-straylight-az700-lb-standard (async)".
#           Confirm the RG is gone later with: az700.sh sweep
```

## What you proved

- Traffic Manager is **global and DNS-based** — it directs by handing back the
  chosen endpoint's address at resolution time and never touches the data path.
  (Contrast: Load Balancer and Application Gateway are regional and *are* the
  data path.)
- The **routing method** is the profile's core decision:
  Priority / Weighted / Performance / Geographic / MultiValue.
- **Endpoints** can be Azure, external (an FQDN/IP), or nested profiles; an
  **HTTP/HTTPS/TCP monitor** removes an unhealthy endpoint from answers.
- Resolving the `*.trafficmanager.net` name returned the priority-1 healthy
  endpoint — the whole mechanism, observable with `nslookup`.
- Because it is DNS, failover is bounded by the record **TTL** (clients cache
  the old answer until it expires) — a key Traffic Manager caveat.
