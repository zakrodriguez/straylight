# vwan-lite

Standard Virtual WAN + one Microsoft-managed virtual hub `vhub1`
(10.103.8.0/23) + spoke VNet `vnet-vwan-spoke1` (10.103.10.0/24) connected to
the hub. Serves the `az700-hybrid-5` walkthrough as a **runbook** (no golden).
The virtual hub takes ~30 min to provision and meters its routing
infrastructure hourly — deploy only for hands-on reps and **destroy the same
day**.

Deploy: `azure/scripts/az700.sh deploy vwan-lite --no-wait` · Teardown: `azure/scripts/az700.sh destroy vwan-lite`
Cost: ~$0.60 per short sitting (virtual hub routing infra ~$0.25/hr + connection ~$0.02/hr + data GB).
