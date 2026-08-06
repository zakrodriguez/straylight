# appgw

**Application Gateway** Standard_v2 (`agw-straylight`, capacity 1) with a
URL-path map: `/images/*` routes to `pool-images` (`vm-appgw2`), everything
else to `pool-default` (`vm-appgw1`). Backends serve their hostname on :80, so
curling the gateway with and without `/images/` proves the routing. The
gateway has its own dedicated `snet-appgw` (/26) subnet. Serves the
`az700-lb-2` walkthrough and is referenced by `az700-lb-3` (WAF, runbook).

**App Gateway takes ~15–20 min to provision** — deploy with `--no-wait` and
gate on `watch`.

Deploy: `azure/scripts/az700.sh deploy appgw --no-wait` · Teardown: `azure/scripts/az700.sh destroy appgw`
Cost: < $0.60 per session (AppGW Standard_v2 ~$0.25/hr + capacity units + 2 × B2ts_v2 + pip). Destroy the same day.
