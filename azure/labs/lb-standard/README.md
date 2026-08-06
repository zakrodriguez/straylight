# lb-standard

Public **Standard Load Balancer** (`lb-straylight`) fronting two backend VMs
(`vm-lb1`, `vm-lb2`) in `vnet-lb` (10.103.12.0/24). Each backend serves its
hostname on :80 via cloud-init (stdlib python, no internet needed), so curling
the frontend public IP proves distribution. NSG admits HTTP from the internet
and from `AzureLoadBalancer` (probes). Serves the `az700-lb-1` walkthrough and
is reused by `az700-lb-4` (Traffic Manager creates a profile pointing at this
LB's public IP).

Deploy: `azure/scripts/az700.sh deploy lb-standard` · Teardown: `azure/scripts/az700.sh destroy lb-standard`
Cost: < $0.30 per session (2 × B2ts_v2 + Standard LB ~$0.025/hr + 1 Standard pip ~$0.004/hr).
