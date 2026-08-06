# AZ-700 Private Lab 1 — Service Endpoints

A PaaS service like a storage account is born with a **public** endpoint. The
first, lightest way to take it off the open internet is a **service
endpoint**: you flag a subnet, and traffic from it to the service rides the
**Azure backbone** instead of the internet, while the service's **firewall**
is locked to that subnet. The service keeps its public IP and public DNS name —
what changes is the path and the firewall. This lab enables a storage service
endpoint on a subnet, locks the account to it, and proves reachability from
inside while everyone else is denied.

Pairs with MS Learn: *Secure access to PaaS* — virtual network service
endpoints (AZ-700 learning path).

> **Before you start**: deploy the topology (a VNet, a storage account, and a
> VM). This lab and **Lab 2 (private endpoint)** share this one deployment —
> run them back-to-back and tear down once at the end.
>
> ```bash
> az account show --query id -o tsv        # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy private-link
> ```
>
> **Cost**: 1 × B2ts_v2 + a storage account (pennies), **< $0.25**.
> **Teardown**: Lab 2's last step (or `azure/scripts/az700.sh destroy
> private-link` now if you stop here).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `azure/scripts/az700.sh deploy private-link` provisioned | the VNet, storage account, and VM must exist |
| az CLI ≥ 2.60, logged in | every step is `az` from the host |
| Verification: VERIFIABLE (walkverify golden, live-capture) | config projections + a from-VM reachability proof |

## Setup (one-time, idempotent)

Confirm the deployment finished and grab the (generated) storage account name:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded
```

## Step 1 — Enable the storage service endpoint on the subnet

A service endpoint is a property of the **subnet**: you declare that this
subnet reaches a given service class over the backbone. Turn on
`Microsoft.Storage` for `snet-workload`, then read it back.

<!-- @verify host=lab step=enable-endpoint expect=/Microsoft.Storage/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
az network vnet subnet update --resource-group $RG --vnet-name vnet-plink \
  --name snet-workload --service-endpoints Microsoft.Storage -o none
az network vnet subnet show --resource-group $RG --vnet-name vnet-plink \
  --name snet-workload --query "serviceEndpoints[].service" -o tsv
# Expected: Microsoft.Storage
```

## Step 2 — Lock the storage firewall to that subnet

The endpoint is only half the story — now restrict the account so **only** that
subnet is allowed and the public default is **Deny**.

<!-- @verify host=lab step=lock-firewall expect=/Deny/ expect=/snet-workload/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
SA=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)
SUBNET=$(az network vnet subnet show --resource-group $RG --vnet-name vnet-plink \
  --name snet-workload --query id -o tsv)
az storage account network-rule add --resource-group $RG --account-name $SA \
  --subnet "$SUBNET" -o none
az storage account update --resource-group $RG --name $SA \
  --default-action Deny -o none
az storage account show --resource-group $RG --name $SA \
  --query "{default:networkRuleSet.defaultAction, allowed:networkRuleSet.virtualNetworkRules[0].virtualNetworkResourceId}" -o json
# Expected: defaultAction Deny, allowed = the snet-workload subnet id
#           (the vnet rule's id is under virtualNetworkResourceId, not id)
```

## Step 3 — Prove reachability from the allowed subnet

From the VM in `snet-workload`, the storage endpoint is reachable over the
service endpoint — a request connects and gets an application-level response
(an auth/query error, not a network block). Anywhere else, the firewall now
denies it.

<!-- @verify host=lab step=reachable expect=/40[0-9]/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
SA=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)
az vm run-command invoke --resource-group $RG --name vm-plink1 \
  --command-id RunShellScript \
  --scripts "curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://$SA.blob.core.windows.net/" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -oE '4[0-9][0-9]' | head -1
# Expected: an HTTP 4xx code (e.g. 400) — the request REACHED storage over the
#           service endpoint and got an app-level error, proving connectivity
#           (a firewall block would time out instead)
```

## Step 4 — The DNS truth (why this is not a private endpoint)

Resolve the storage name from the VM. Note it still returns a **public**
address — a service endpoint does **not** change DNS. The account keeps its
public name and public IP; the endpoint changed the **route** (backbone) and
the **firewall** (subnet-only). This is the exact thing a **private endpoint**
(Lab 2) does differently.

<!-- @verify host=lab step=dns-public expect=/store.core.windows.net/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
SA=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)
az vm run-command invoke --resource-group $RG --name vm-plink1 \
  --command-id RunShellScript \
  --scripts "getent hosts $SA.blob.core.windows.net" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -oE '[^ ]+\.store\.core\.windows\.net' | head -1
# Expected: a *.store.core.windows.net backend — the public name resolves to a
#           PUBLIC storage endpoint (service endpoints don't change DNS;
#           contrast Lab 2, where the same name becomes a private 10.x IP)
```

## What you proved

- A **service endpoint** is a **subnet** property: traffic to the PaaS service
  class rides the **Azure backbone**, and you lock the service **firewall** to
  the subnet (default Deny + allow the subnet).
- The service keeps its **public IP and public DNS name** — a service endpoint
  changes the **route and the firewall**, not resolution.
- From the allowed subnet the endpoint is reachable (app-level response); from
  anywhere else the firewall denies it.
- The limits (and why private endpoints exist): service endpoints are
  **regional-ish**, don't extend to on-prem over VPN/ER, and still expose a
  public endpoint. When you need a **private IP** and **on-prem reach**, that's
  a **private endpoint** — Lab 2.
