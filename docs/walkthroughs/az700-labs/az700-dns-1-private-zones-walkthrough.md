# AZ-700 DNS Lab 1 — Private Zones, VNet Links, and Auto-Registration

Every VM in a VNet can already resolve names — Azure's wire server at
`168.63.129.16` answers before you configure anything. What it answers
*with* is the interesting part. This lab creates a private DNS zone, links
it to two VNets with different powers (one may register, one may only
resolve), watches Azure auto-register a VM's record without being asked,
adds a static record by hand, and proves resolution from inside a VM — all
without a single DNS server of your own.

Pairs with MS Learn: *Design and implement name resolution* — private DNS
zones and virtual-network links (AZ-700 learning path, Design and implement
core networking infrastructure).

> **Before you start**: no Straylight VMs are needed (azure-only lab). You
> need an Azure subscription with az CLI logged in and the shared topology
> deployed:
>
> ```bash
> az account show --query id -o tsv          # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy hub-spoke    # hub + 2 spokes + 1 B2ts_v2 VM (~2 min)
> ```
>
> Labs 1–2 of this module share that one deployment — run them back-to-back
> in a single session and tear down once at the end.
>
> **Cost**: < $0.25 for the session (one B2ts_v2 VM; the private zone is
> ~$0.50/month prorated, queries negligible).
> **Teardown when done**: `azure/scripts/az700.sh destroy hub-spoke`
> (Step 6 — skip it only if you are continuing to Lab 2 in the same sitting).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Azure subscription + az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `azure/scripts/az700.sh deploy hub-spoke` run this session | provides the RG, vnet-spoke1/2, and vm-spoke1 |
| Azure spend this session: < $0.25 | one B2ts_v2; DNS zones are ~free at lab timescales |
| Teardown: `az700.sh destroy hub-spoke` (Step 6) | same-day teardown is the track's budget model |
| Verification: VERIFIABLE (walkverify golden) | pure az CLI with `-o tsv` projections |

## Setup (one-time, idempotent)

Every code block in this lab is self-contained — each one names the resource
group itself, so any block can be re-run standalone. Confirm the deployment
finished:

<!-- @verify host=lab step=deploy-precheck expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az deployment group show --resource-group $RG --name main \
  --query properties.provisioningState -o tsv
# Expected: Succeeded   (anything else: run azure/scripts/az700.sh deploy hub-spoke)
```

## Step 1 — Create the private zone

A private DNS zone is a **name container with no servers**: Azure's
resolver fabric answers for it, and only VNets you explicitly *link* can
see it. The name can be anything — it never touches public DNS. The track
uses the RFC 2606 reserved TLD so nothing can ever collide with a real
domain:

<!-- @verify host=lab step=create-zone expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network private-dns zone create --resource-group $RG \
  --name internal.straylight.example \
  --query provisioningState -o tsv
# Expected: Succeeded
```

A zone alone answers nobody. Resolution is governed entirely by
**virtual-network links**, which come in two strengths — that's Step 2.

## Step 2 — Two links, two powers

Link `vnet-spoke1` with **auto-registration enabled**: VMs in that VNet get
A records created (and cleaned up) for them automatically:

<!-- @verify host=lab step=link-registration expect=/true/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network private-dns link vnet create --resource-group $RG \
  --zone-name internal.straylight.example --name link-spoke1-reg \
  --virtual-network vnet-spoke1 --registration-enabled true \
  --query registrationEnabled -o tsv
# Expected: true
```

Link `vnet-spoke2` as **resolution-only** — its VMs can look names up but
never write records:

<!-- @verify host=lab step=link-resolution expect=/false/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network private-dns link vnet create --resource-group $RG \
  --zone-name internal.straylight.example --name link-spoke2-res \
  --virtual-network vnet-spoke2 --registration-enabled false \
  --query registrationEnabled -o tsv
# Expected: false
```

The exam's favorite constraints live right here. A zone accepts up to
**100 registration links** and **1000 resolution links** — but a given
**VNet can auto-register into only one private zone**, ever. Every linked
VNet (either kind) resolves **all** records in the zone; the registration
flag only controls who may *write*.

## Step 3 — Watch auto-registration happen

`vm-spoke1` existed before the zone did. Azure back-fills registrations for
existing VMs — it takes a moment, so poll rather than read once:

<!-- @verify host=lab step=autoreg-record expect=/^REGISTERED$/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
for i in $(seq 1 24); do
  n=$(az network private-dns record-set a list --resource-group $RG \
    --zone-name internal.straylight.example \
    --query "length([?name=='vm-spoke1'])" -o tsv)
  [ "$n" = "1" ] && echo REGISTERED && break
  sleep 10
done
# Expected: REGISTERED   (usually well under a minute; 4-minute ceiling)
```

Nothing configured this record: the platform saw a VM in a
registration-linked VNet and wrote `vm-spoke1` → its private IP. When the
VM is deleted or deallocated, the record goes away just as silently — the
zone stays truthful without an operator.

## Step 4 — A static record beside the automatic one

Zones aren't only for VMs. Add a record by hand — a service name pointing
at an address that no machine currently owns (fine for DNS; existence is
not a prerequisite):

<!-- @verify host=lab step=static-record expect=/10\.101\.0\.250/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network private-dns record-set a add-record --resource-group $RG \
  --zone-name internal.straylight.example \
  --record-set-name myapp --ipv4-address 10.101.0.250 \
  --query "aRecords[0].ipv4Address" -o tsv
# Expected: 10.101.0.250
```

## Step 5 — Prove resolution from inside a VM

Ask `vm-spoke1` to resolve both records. The queries ride the VNet's
default DNS path — the wire server at `168.63.129.16` — which consults
linked private zones before anything else. (`run-command` reaches the VM
over the control plane; the *DNS lookup* is what exercises the network.)

The static record first:

<!-- @verify host=lab step=resolve-static expect=/10\.101\.0\.250/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az vm run-command invoke --resource-group $RG --name vm-spoke1 \
  --command-id RunShellScript \
  --scripts "nslookup myapp.internal.straylight.example" \
  --query "value[0].message" -o tsv
# Expected: output containing 10.101.0.250 (allow ~30-60s; run-command is slow)
```

Then the auto-registered one — the VM resolving *itself* through the zone:

<!-- @verify host=lab step=resolve-autoreg expect=/10\.101\.0\./ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az vm run-command invoke --resource-group $RG --name vm-spoke1 \
  --command-id RunShellScript \
  --scripts "nslookup vm-spoke1.internal.straylight.example" \
  --query "value[0].message" -o tsv
# Expected: output containing the VM's 10.101.0.x address
```

Two things worth locking in. First, `168.63.129.16` is a fixed, virtual
address — the same in every VNet in every region, reachable only from
inside Azure; know it on sight for the exam. Second, **split-horizon is
automatic**: if a linked private zone and public DNS both hold a name, the
private zone wins for linked VNets — that's the standard pattern for
private endpoints (`privatelink.*` zones), which the private-access module
builds on.

## Step 6 — Teardown

**Continuing to Lab 2 in this sitting? Skip this step** — it ends the
whole module session.

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy hub-spoke
# Expected: "delete submitted for rg-straylight-az700-hub-spoke (async)"
```

The resource group is the state: the zone, both links, and every record —
automatic and static — die with it. Confirm later with
`azure/scripts/az700.sh list` or `az group list --tag track=az700 -o table`.

## What you proved

- A private DNS zone is serverless name storage; **links**, not the zone,
  decide who resolves it — and registration links additionally let the
  platform write VM records automatically, back-filling existing VMs.
- One VNet auto-registers into at most one zone; zones take up to 100
  registration and 1000 resolution links; every linked VNet resolves all
  records regardless of link type.
- In-VNet resolution flows through `168.63.129.16`, which consults linked
  private zones first — split-horizon over public DNS is the default, not
  a feature you enable.
