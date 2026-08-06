# private-link

One VNet `vnet-plink` (10.103.16.0/24) with `snet-workload` (the VM + the
service-endpoint subject) and `snet-pe` (private endpoints, network policies
disabled), plus a StorageV2 account (`st<uniqueString>`, globally unique per
RG) and a B2ts_v2 VM. Serves `az700-private-1` (service endpoints) and
`az700-private-2` (private endpoint to storage) — the labs restrict then
privatise the same storage account as lab steps, so everything dies with the
RG.

Deploy: `azure/scripts/az700.sh deploy private-link` · Teardown: `azure/scripts/az700.sh destroy private-link`
Cost: < $0.30 per session (1 × B2ts_v2 + storage pennies + 1 private endpoint ~$0.01/hr in lab 2).
