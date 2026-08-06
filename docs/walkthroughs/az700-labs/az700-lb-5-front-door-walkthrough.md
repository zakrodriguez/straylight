# AZ-700 LB Lab 5 — Azure Front Door

Azure Front Door is the **global** application delivery service: a Layer-7
reverse proxy running on the **Microsoft edge network**, terminating TLS close
to the user, caching static content at the POPs, filtering with a WAF at the
edge, and routing to the best origin. Where Traffic Manager (Lab 4) only
answers DNS and Application Gateway (Lab 2) is regional, Front Door is the one
that is *both* global *and* on the data path. This lab is a **runbook**: Front
Door is edge-latency- and propagation-dependent (POP rollout takes minutes and
varies), so it teaches the model and the decision rather than asserting live
behaviour.

Pairs with MS Learn: *Design and implement application delivery* — Azure Front
Door (AZ-700 learning path).

> **Runbook lab (no walkverify golden)**. Commands are shown with the shapes to
> expect. Front Door Standard has a base monthly fee plus per-route and
> data/request charges; stand it up only for hands-on reps.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Labs 1–2 concepts (backend pool, L7 routing) | Front Door's origin group + route mirror them at global scale |
| az CLI ≥ 2.60, logged in (`az extension add --name front-door` for classic) | commands are `az afd` (Standard/Premium) from the host |
| Verification: RUNBOOK (no golden, no `@verify`) | edge propagation is latency-dependent, not a CI/gate step |

## The model, before the commands

Front Door Standard/Premium is a small tree of objects:

- **Profile** — the Front Door instance (Standard or Premium; Premium adds
  Private Link origins and the full managed WAF ruleset).
- **Endpoint** — a `*.z01.azurefd.net` hostname the client hits (plus your own
  custom domains).
- **Origin group** — the set of backends (**origins**) for a workload, with the
  **health probe** and **load-balancing** settings (latency sensitivity,
  sample size). An origin can be an App Service, a Load Balancer/App Gateway
  public IP, a storage account, or any public host.
- **Origin** — one backend in the group, with a **priority** and **weight**
  (Front Door does priority + weighted origin selection *inside* the chosen
  POP's routing).
- **Route** — ties an endpoint + a set of paths/domains to an origin group,
  and carries the **caching** and **rules** behaviour.

Two capabilities define why you would pick Front Door over the regional
services:

- **Edge termination + caching** — TLS terminates and static responses are
  cached at the **POP nearest the user**, so latency and origin load drop
  globally. App Gateway can't cache; Traffic Manager isn't on the path to.
- **Edge WAF** — the same managed-ruleset + custom-rule WAF as Lab 3, but
  enforced at the **edge**, dropping bad requests before they enter any region.

## Runbook — a minimal Standard profile, endpoint, origin, route

```bash
RG=rg-straylight-az700-frontdoor
az group create -n $RG -l centralus \
  --tags project=straylight track=az700 lab=frontdoor

# 1. Profile (Standard tier)
az afd profile create --resource-group $RG --profile-name afd-straylight \
  --sku Standard_AzureFrontDoor

# 2. Endpoint (the *.azurefd.net hostname clients hit)
az afd endpoint create --resource-group $RG --profile-name afd-straylight \
  --endpoint-name straylight --enabled-state Enabled

# 3. Origin group + health probe + load-balancing settings
az afd origin-group create --resource-group $RG --profile-name afd-straylight \
  --origin-group-name og-web \
  --probe-request-type GET --probe-protocol Http --probe-path "/" \
  --probe-interval-in-seconds 60 \
  --sample-size 4 --successful-samples-required 3 --additional-latency-in-milliseconds 50

# 4. Origin (a public backend — e.g. the Lab 1 LB IP, an App Service, storage)
az afd origin create --resource-group $RG --profile-name afd-straylight \
  --origin-group-name og-web --origin-name origin1 \
  --host-name www.example.com --origin-host-header www.example.com \
  --priority 1 --weight 1000 --enabled-state Enabled --http-port 80 --https-port 443

# 5. Route (endpoint + paths -> origin group, with caching)
az afd route create --resource-group $RG --profile-name afd-straylight \
  --endpoint-name straylight --route-name route1 \
  --origin-group og-web --supported-protocols Http Https \
  --patterns-to-match "/*" --forwarding-protocol MatchRequest \
  --link-to-default-domain Enabled --enable-caching true

# Read the endpoint hostname the client will use:
az afd endpoint show --resource-group $RG --profile-name afd-straylight \
  --endpoint-name straylight --query hostName -o tsv
#   Expect: straylight-<hash>.z01.azurefd.net  (allow minutes for edge rollout)
```

## Runbook — caching and the rules engine

- **Caching** is per-route (`--enable-caching`): Front Door caches cacheable
  responses at the POP. Query-string behaviour and cache duration are tuned per
  route / via the rules engine.
- The **rules engine** (`az afd rule ...`) rewrites/redirects, sets headers,
  and overrides caching by match condition (path, header, geo) — the edge
  equivalent of App Gateway's rewrite rules.
- The **WAF** attaches via a **security policy** (`az afd security-policy`)
  linking a WAF policy to the endpoint's domains — same Detection/Prevention +
  managed/custom model as Lab 3, at the edge.

## The decision (what the exam is really testing)

| Need | Service |
|---|---|
| L4, regional, TCP/UDP to VMs | **Load Balancer** (Lab 1) |
| L7, regional, URL/host routing, regional WAF | **Application Gateway** (Labs 2–3) |
| Global, DNS-only director, no data path, cross-service | **Traffic Manager** (Lab 4) |
| Global, L7 on the edge, caching + edge WAF + TLS offload | **Azure Front Door** (this lab) |

Common real designs **combine** them: Front Door at the edge (global entry +
caching + WAF) in front of regional App Gateways (L7 routing + regional WAF) in
front of Load Balancers (L4 to the VMs). Traffic Manager still appears where
you need DNS-level routing across services Front Door doesn't front.

## What you learned (runbook)

- Front Door is **global Layer-7 on the Microsoft edge**: profile → endpoint →
  origin group (probe + LB settings) → origins (priority/weight) → route
  (paths + caching + rules).
- Its differentiators are **edge caching/TLS offload** and an **edge WAF** —
  neither of which the regional services offer.
- Pick by the four-way decision table above; production stacks frequently
  **layer** Front Door → App Gateway → Load Balancer, with Traffic Manager for
  DNS-level cross-service routing.
