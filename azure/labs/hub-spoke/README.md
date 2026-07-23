# hub-spoke

Hub VNet (10.100.0.0/22) + vnet-spoke1/vnet-spoke2 (unpeered — the labs create
the peerings) + one burstable test VM (B2ts_v2) in spoke1. Serves the `az700-vnet` walkthroughs.

Deploy: `azure/scripts/az700.sh deploy hub-spoke` · Teardown: `azure/scripts/az700.sh destroy hub-spoke`
Cost: < $0.25 per session (1 × B2ts_v2 (~$0.01/hr); VNets/peerings free at lab volume).
