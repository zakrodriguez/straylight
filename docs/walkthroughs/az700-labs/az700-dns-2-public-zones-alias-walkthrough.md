# AZ-700 DNS Lab 2 — Public Zones, Record Sets, and Alias Records

A public DNS zone in Azure is real, internet-grade DNS — Azure assigns four
name servers and answers the world's queries — with one twist this lab
exploits: you can host any zone name without owning it, because nothing
resolves through your zone until a registrar delegates to it. That makes a
reserved-TLD zone a perfect sandbox. This lab creates one, fills it with
ordinary records, proves resolution by querying Azure's name servers
directly with `dig`, and then builds the record type the exam cares most
about: an **alias record** that tracks an Azure resource instead of an
address.

Pairs with MS Learn: *Design and implement name resolution* — public DNS
zones and record sets (AZ-700 learning path, Design and implement core
networking infrastructure).

> **Before you start**: no Straylight VMs are needed (azure-only lab). You
> need an Azure subscription with az CLI logged in, `dig` on the host
> (`bind9-dnsutils`), and the shared topology deployed:
>
> ```bash
> az account show --query id -o tsv          # must equal AZURE_SUBSCRIPTION_ID in vagrant/.env
> azure/scripts/az700.sh deploy hub-spoke    # hub + 2 spokes + 1 B2ts_v2 VM (~2 min)
> ```
>
> If you just finished Lab 1 in this sitting, the deployment is already up
> (the deploy is idempotent if you run it anyway). Only the resource group
> itself matters to this lab.
>
> **Cost**: < $0.25 for the session (the zone is ~$0.50/month prorated; one
> Standard public IP at ~$0.004/hr for the alias exercise).
> **Teardown when done**: `azure/scripts/az700.sh destroy hub-spoke`
> (Step 6). This lab **ends** the module's shared session.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Azure subscription + az CLI ≥ 2.60, logged in | every step is `az` from the host |
| `dig` on the host (`bind9-dnsutils`) | resolution proof queries the zone's Azure NS directly |
| `azure/scripts/az700.sh deploy hub-spoke` run this session | provides the RG the zone lives in |
| Azure spend this session: < $0.25 | zone + one Standard public IP; nothing hourly-expensive |
| Teardown: `az700.sh destroy hub-spoke` (Step 6) | this lab closes the module's shared deployment |
| Verification: VERIFIABLE (walkverify golden) | az CLI projections + `dig +short` one-liners |

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

## Step 1 — Create the zone and meet your name servers

<!-- @verify host=lab step=create-zone expect=/azure-dns\.com/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network dns zone create --resource-group $RG \
  --name straylight.example \
  --query "nameServers[0]" -o tsv
# Expected: something like ns1-NN.azure-dns.com. (the partition number varies)
```

Azure assigned four name servers across four TLDs (`azure-dns.com`, `.net`,
`.org`, `.info`) — resilience against a TLD-level outage. Creating the zone
also wrote its **SOA** and **NS** records; those two exist in every zone
and cannot be deleted.

What Azure did *not* do is tell the internet. Public resolution of
`straylight.example` would require the `.example` registry to delegate to
these name servers — which is exactly the step you'd do at your registrar
for a real domain, and exactly the step this reserved TLD guarantees can
never happen. The zone is live; the delegation is absent; `dig @<ns>` talks
to the zone directly and skips the delegation question entirely.

## Step 2 — Ordinary records: A and CNAME

An **A record** maps a name to an IPv4 address (the address is from
`203.0.113.0/24`, the documentation range — DNS never checks existence):

<!-- @verify host=lab step=record-a expect=/<PUBIP>|203\.0\.113\.10/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network dns record-set a add-record --resource-group $RG \
  --zone-name straylight.example \
  --record-set-name www --ipv4-address 203.0.113.10 \
  --query "ARecords[0].ipv4Address" -o tsv
# Expected: 203.0.113.10
```

(Casing quirk worth knowing: the *public* DNS commands emit REST-style
keys — `ARecords`, `CNAMERecord`, `TTL` — while the *private* DNS commands
from Lab 1 emit `aRecords`. JMESPath is case-sensitive; a silent empty
output usually means you guessed the wrong one.)

A **CNAME** aliases one name to another — note it points at a *name*, and
that a CNAME record set can hold exactly one record:

<!-- @verify host=lab step=record-cname expect=/www\.straylight\.example/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network dns record-set cname set-record --resource-group $RG \
  --zone-name straylight.example \
  --record-set-name docs --cname www.straylight.example \
  --query "CNAMERecord.cname" -o tsv
# Expected: www.straylight.example
```

Record sets carry the **TTL** (default 3600 s here). TTL is a cache lease:
long TTLs cut query load but stretch how stale the world may be after a
change. The standard migration move — drop the TTL *before* the change,
raise it after — is exam material.

## Step 3 — Prove resolution against the zone's own NS

Ask the zone's first name server directly. `dig +short @<ns>` bypasses
every cache and every delegation — the answer comes straight from Azure's
authoritative servers:

<!-- @verify host=lab step=dig-a expect=/<PUBIP>|203\.0\.113\.10/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
NS=$(az network dns zone show --resource-group $RG \
  --name straylight.example --query "nameServers[0]" -o tsv)
dig +short @$NS www.straylight.example
# Expected: 203.0.113.10
```

That answer came from the public internet — the zone works; only the
delegation is missing. For a real domain, the go-live moment is pasting
these four NS names into the registrar, nothing more.

## Step 4 — The alias record

A plain A record holding an Azure public IP's address rots the moment the
resource is rebuilt. An **alias record** targets the *resource* instead:
Azure keeps the answer in sync with the IP's current address and cleans the
record when the resource dies. Allocate an IP, then alias to it:

<!-- @verify host=lab step=create-pip expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network public-ip create --resource-group $RG --name pip-dnslab \
  --sku Standard --query publicIp.provisioningState -o tsv
# Expected: Succeeded
```

<!-- @verify host=lab step=record-alias expect=/pip-dnslab/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
az network dns record-set a create --resource-group $RG \
  --zone-name straylight.example --name app \
  --target-resource "$(az network public-ip show --resource-group $RG \
    --name pip-dnslab --query id -o tsv)" \
  --query "targetResource.id" -o tsv
# Expected: a resource ID ending in /publicIPAddresses/pip-dnslab
```

Alias records exist for A, AAAA, and CNAME types, and can target public
IPs, Traffic Manager profiles, CDN endpoints, Front Door — or another
record set in the same zone. The exam's favorite corner: DNS forbids a
CNAME at the **zone apex** (`straylight.example` itself), and an alias A
record at the apex is the sanctioned way to point an apex at an Azure
resource anyway.

## Step 5 — Resolve the alias

Same direct-to-NS probe; the answer is whatever address Azure allocated to
`pip-dnslab` — an address you never typed into the zone:

<!-- @verify host=lab step=dig-alias expect=/<PUBIP>|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/ rc=0 -->
```bash
RG=rg-straylight-az700-hub-spoke
NS=$(az network dns zone show --resource-group $RG \
  --name straylight.example --query "nameServers[0]" -o tsv)
dig +short @$NS app.straylight.example
# Expected: the public IP Azure allocated to pip-dnslab
```

If the IP resource were deleted, the alias record would empty itself rather
than serve a dead address — compare that with the `www` A record, which
would happily serve `203.0.113.10` forever.

## Step 6 — Teardown

This step ends the module's shared session — nothing after this lab reuses
the topology:

<!-- @verify host=lab step=teardown expect=/delete submitted/ rc=0 -->
```bash
azure/scripts/az700.sh destroy hub-spoke
# Expected: "delete submitted for rg-straylight-az700-hub-spoke (async)"
```

The resource group is the state: the zone, its records, the alias target
public IP — all die with it. (A public zone with records is deletable at
any time; nothing holds a lock.) Confirm later with
`azure/scripts/az700.sh list` or `az group list --tag track=az700 -o table`.

## What you proved

- A public zone is authoritative the instant it exists — four NS across
  four TLDs, SOA/NS records built in — and *delegation at the registrar*
  is the only thing separating a sandbox zone from a live one.
- `dig +short @<ns>` interrogates the authoritative servers directly:
  the cleanest way to verify a zone before (or without) delegation.
- Record sets carry the TTL; CNAMEs point at names, hold one record, and
  are illegal at the zone apex.
- Alias records track Azure *resources*, not addresses — self-updating,
  self-cleaning, and the sanctioned apex workaround.
