# AZ-700 Private Lab 3 — Private Link Service

Labs 1–2 were the **consumer** side of Private Link — reaching *someone else's*
PaaS privately. **Private Link Service (PLS)** is the **provider** side: you
publish *your own* service so that other tenants or VNets reach it by a
**private endpoint**, never over the internet, without peering your networks.
It is how Azure itself offers storage/SQL as Private Link, and how you offer a
SaaS to customers. This lab is a **runbook**: the full value needs a second
(consumer) network and the NAT/approval mechanics are fiddly, so it teaches the
model and the provider setup against a documented deployment rather than
asserting a live cross-tenant connection.

Pairs with MS Learn: *Secure access to PaaS* — Azure Private Link Service
(AZ-700 learning path).

> **Runbook lab (no walkverify golden)**. Commands are shown with the shapes to
> expect. A PLS needs an **internal Standard Load Balancer** to front it; deploy
> only for hands-on reps and tear down the same day.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Labs 1–2 concepts (private endpoint, private DNS) | the consumer reaches a PLS *with* a private endpoint |
| az CLI ≥ 2.60, logged in | commands are `az` from the host |
| Verification: RUNBOOK (no golden, no `@verify`) | the value needs a second consumer VNet; NAT/approval is deploy-heavy |

## The model, before the commands

Private Link has two sides:

- **Consumer** (Labs 1–2): a **private endpoint** in *your* VNet targeting a
  service — a Microsoft PaaS resource, or someone's **PLS alias**.
- **Provider** (this lab): a **Private Link Service** over an **internal
  Standard Load Balancer** frontend, which you expose by an **alias**.
  Consumers create a private endpoint pointing at that alias; you **approve**
  the connection.

Four things define a PLS:

1. **Internal Standard LB frontend** — the PLS sits on an internal LB's frontend
   IP configuration (your service's backends are in the LB pool). Standard SKU,
   internal — a public LB or Basic SKU won't do.
2. **NAT subnet(s)** — the PLS allocates IPs from a subnet (with
   `privateLinkServiceNetworkPolicies` disabled) to source-NAT consumer traffic,
   so provider and consumer address spaces never have to be coordinated.
3. **Alias** — the globally-unique name (`<pls>.<guid>.<region>.azure.privatelinkservice`)
   you hand consumers; they target it with a private endpoint.
4. **Visibility + approval** — who can see/request the service (a role/sub
   allow-list or "anyone with the alias"), and whether connections **auto-
   approve** or wait for you.

## Runbook — deploy the provider side

```bash
RG=rg-straylight-az700-pls
az group create -n $RG -l centralus \
  --tags project=straylight track=az700 lab=pls -o none

# VNet: a backend subnet + a dedicated NAT subnet for the PLS.
az network vnet create -g $RG -n vnet-pls --address-prefixes 10.103.20.0/24 \
  --subnet-name snet-backend --subnet-prefixes 10.103.20.0/27 -o none
az network vnet subnet create -g $RG --vnet-name vnet-pls -n snet-nat \
  --address-prefixes 10.103.20.32/27 \
  --disable-private-link-service-network-policies true -o none

# Internal Standard LB (frontend in the backend subnet) — the PLS frontend.
az network lb create -g $RG -n lb-pls --sku Standard \
  --vnet-name vnet-pls --subnet snet-backend \
  --frontend-ip-name feip --backend-pool-name bepool -o none

# The Private Link Service over that LB frontend, NAT IPs from snet-nat.
az network private-link-service create -g $RG -n pls-straylight \
  --vnet-name vnet-pls --subnet snet-nat \
  --lb-name lb-pls --lb-frontend-ip-configs feip \
  --query "{state:provisioningState, alias:alias}" -o json
#   Expect: provisioningState Succeeded, and an alias
#           pls-straylight.<guid>.<region>.azure.privatelinkservice
```

## Runbook — the consumer side (a second VNet)

```bash
# In the CONSUMER's VNet, a private endpoint targets the PLS ALIAS (not a
# resource id) — that is the whole point: no peering, no shared address space.
ALIAS=$(az network private-link-service show -g $RG -n pls-straylight --query alias -o tsv)
az network private-endpoint create -g <consumer-rg> -n pe-to-pls \
  --vnet-name <consumer-vnet> --subnet <consumer-subnet> \
  --private-connection-resource-id "$ALIAS" --connection-name c1 --manual-request true

# The provider approves the pending connection:
az network private-link-service connection update -g $RG \
  --service-name pls-straylight -n <connection-name> --connection-status Approved
```

## Runbook — teardown

```bash
az group delete -n rg-straylight-az700-pls --yes --no-wait
```

## What you learned (runbook)

- **Private Link Service** is the **provider** side: publish your own service
  (behind an **internal Standard LB**) for consumers to reach by **private
  endpoint** — no peering, no shared address space, no internet.
- It needs an **internal Standard LB frontend**, a **NAT subnet** (network
  policies disabled) to source-NAT consumer traffic, and it exposes an
  **alias** consumers target.
- **Visibility + approval** control who can request the service and whether
  connections auto-approve — the provider stays in charge.
- Consumers point a private endpoint at the **alias** (not a resource id) and
  the provider **approves** — the same private-endpoint object as Lab 2, aimed
  at your service instead of a Microsoft PaaS.
