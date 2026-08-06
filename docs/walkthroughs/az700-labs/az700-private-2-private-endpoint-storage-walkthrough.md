# AZ-700 Private Lab 2 — Private Endpoint to Storage

A service endpoint (Lab 1) kept the storage account's public identity and just
fenced it. A **private endpoint** goes all the way: it puts a **NIC with a
private IP from your VNet** in front of the storage account, and — the part
that makes it work transparently — it wires **private DNS** so the account's
ordinary public name resolves to that **private IP**. Applications keep using
`account.blob.core.windows.net`; the name now points inside your network. This
lab creates the private endpoint, the private DNS zone that makes resolution
work, and then proves it: a VM resolves the public storage name and gets back a
`10.x` address.

Pairs with MS Learn: *Secure access to PaaS* — Azure Private Link / private
endpoints and private DNS integration (AZ-700 learning path).

> **Before you start**: this lab **reuses the `private-link` deployment** from
> Lab 1. If it is still up, continue straight in; if not:
>
> ```bash
> azure/scripts/az700.sh deploy private-link
> ```
>
> **Cost**: a private endpoint (~$0.01/hr) + a private DNS zone (pennies) on
> top of Lab 1's deployment — **effectively free** for a sitting.
> **Teardown**: Step 6 tears down the whole `private-link` deployment.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `azure/scripts/az700.sh deploy private-link` provisioned | the VNet, storage account, and VM must exist |
| az CLI ≥ 2.60, logged in | every step is `az` from the host |
| Verification: VERIFIABLE (walkverify golden, live-capture) | config projections + a from-VM private-DNS resolution proof |

## Setup (one-time, idempotent)

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded
```

## Step 1 — Create the private endpoint

A private endpoint targets a specific **sub-resource** of the PaaS service
(`blob`, `file`, `table`, … for storage). It lands a NIC in `snet-pe` with a
private IP.

<!-- @verify host=lab step=create-pe expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
SA=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)
SAID=$(az storage account show --resource-group $RG --name $SA --query id -o tsv)
az network private-endpoint create --resource-group $RG --name pe-storage \
  --vnet-name vnet-plink --subnet snet-pe \
  --private-connection-resource-id "$SAID" --group-id blob \
  --connection-name pe-conn \
  --query provisioningState -o tsv
# Expected: Succeeded
```

## Step 2 — Create the private DNS zone and link it to the VNet

The magic name is fixed: **`privatelink.blob.core.windows.net`**. Azure resolves
`account.blob.core.windows.net` to a CNAME
`account.privatelink.blob.core.windows.net`, so a private zone by that exact
name — **linked to the VNet** — is what redirects the public name to the
private IP.

<!-- @verify host=lab step=dns-zone expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
az network private-dns zone create --resource-group $RG \
  --name privatelink.blob.core.windows.net -o none
az network private-dns link vnet create --resource-group $RG \
  --zone-name privatelink.blob.core.windows.net --name link-plink \
  --virtual-network vnet-plink --registration-enabled false \
  --query provisioningState -o tsv
# Expected: Succeeded
```

## Step 3 — Bind the endpoint to the zone (auto-registers the A record)

A **private DNS zone group** ties the private endpoint to the zone, so Azure
creates and maintains the A record (`account` → the PE's private IP)
automatically — no hand-managed records.

<!-- @verify host=lab step=zone-group expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
az network private-endpoint dns-zone-group create --resource-group $RG \
  --endpoint-name pe-storage --name default \
  --private-dns-zone privatelink.blob.core.windows.net --zone-name blob \
  --query provisioningState -o tsv
# Expected: Succeeded
```

## Step 4 — Read the private endpoint's private IP

<!-- @verify host=lab step=pe-ip expect=/10\.103\.16/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
# The private endpoint's IP lives on its NIC — read it via the NIC.
NICID=$(az network private-endpoint show --resource-group $RG --name pe-storage \
  --query "networkInterfaces[0].id" -o tsv)
az network nic show --ids "$NICID" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv
# Expected: a 10.103.16.x address (the private endpoint's NIC address in snet-pe)
```

## Step 5 — Prove it: resolve the public name to the private IP

The payoff. From the VM, resolve the storage account's **public** blob name.
Because the private zone is linked to the VNet, it comes back as the **private**
`10.103.16.x` address — the application uses the same name, but the traffic
never leaves the network.

<!-- @verify host=lab step=resolve-private expect=/10\.103\.16/ rc=0 -->
```bash
RG=rg-straylight-az700-private-link
SA=$(az storage account list --resource-group $RG --query "[0].name" -o tsv)
az vm run-command invoke --resource-group $RG --name vm-plink1 \
  --command-id RunShellScript \
  --scripts "getent hosts $SA.blob.core.windows.net" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -oE '10\.103\.16\.[0-9]+' | head -1
# Expected: a 10.103.16.x address — the public blob name now resolves to the
#           private endpoint (contrast Lab 1, where it stayed public)
```

## Step 6 — Teardown

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy private-link
# Expected: "delete submitted for rg-straylight-az700-private-link (async)".
#           Confirm the RG is gone later with: az700.sh sweep
```

## What you proved

- A **private endpoint** puts a **NIC with a private VNet IP** in front of a
  PaaS **sub-resource** (`blob`), so the service is reachable at a private
  address.
- **Private DNS** is what makes it transparent: a
  **`privatelink.blob.core.windows.net`** zone **linked to the VNet**, with a
  **DNS zone group** auto-maintaining the A record, so the ordinary public name
  resolves to the private IP.
- The from-VM resolution returned `10.103.16.x` — the same name apps already
  use, now pointing inside the network (vs Lab 1's service endpoint, where DNS
  stayed public).
- Because it's a **private IP + private DNS**, a private endpoint is reachable
  from **peered VNets and on-prem over VPN/ExpressRoute** — the basis for the
  hybrid resolution in Lab 4.
