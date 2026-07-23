# azure/ — AZ-700 track infrastructure

Bicep topologies and a deploy/teardown driver for the AZ-700 (Azure Network
Engineer) walkthrough track in [docs/walkthroughs](../docs/walkthroughs/README.md).
Everything here is **ephemeral by design**: each lab session deploys into its
own resource group, runs the walkthrough, and tears the group down the same
day. There is no state file — the resource group is the state.

## Prerequisites

- An Azure subscription (pay-as-you-go is fine; the whole track is designed
  around single-digit dollars per session).
- az CLI ≥ 2.60 with Bicep (`az bicep install`), logged in via
  `az login --use-device-code`.
- Recommended: pin the subscription in `vagrant/.env`
  (`AZURE_SUBSCRIPTION_ID=<guid>`) — the driver refuses to deploy anywhere
  else. Copy `vagrant/.env.example` to get started.
- One-time: `azure/scripts/az700.sh init` (creates a $25/month budget with
  email alerts and the local claims file).

## Usage

```bash
azure/scripts/az700.sh deploy hub-spoke     # before a lab (walkthroughs name the slug)
azure/scripts/az700.sh destroy hub-spoke    # after — always, same day
azure/scripts/az700.sh sweep                # "did I leave anything running?"
azure/scripts/az700.sh nuke                 # delete every track resource group
```

Slow topologies (VPN gateways: 30–45 min) deploy with `--no-wait`; the
walkthrough gates on `az700.sh watch <slug>`.

## Safety rules

1. Teardown is the last step of every walkthrough, not an afterthought.
2. Every deploy first surfaces any surviving track resource group.
3. All destructive commands match by name prefix `rg-straylight-az700-` AND
   tag `track=az700` — nothing else in the subscription is ever touched.
4. The budget alert is a backstop, not a brake — budgets alert, they do not
   stop spend ([docs/teardown.md](docs/teardown.md)).
5. Expensive SKUs are structurally absent: no ExpressRoute, Azure Firewall
   Standard/Premium, or DDoS plans exist in any topology (`labs/paper/` covers
   them as paper labs). Gateways are `@allowed`-pinned to VpnGw1AZ/VpnGw2AZ,
   VMs to cheap burstable sizes (Bsv2 gen + B1s/B2s).
6. Optional nightly cleanup timer: [scripts/systemd](scripts/systemd/README.md).

## Layout

| Path | Contents |
|---|---|
| `modules/` | shared Bicep building blocks (naming/tags/address plan, hub, spoke, test VM) |
| `labs/<slug>/` | one deployable topology per lab family; `main.bicep` + short README |
| `labs/paper/` | doc-only paper labs for un-frugal topics (arrives with later modules) |
| `scripts/az700.sh` | driver: init / deploy / watch / destroy / list / sweep / nuke / update-onprem-ip / cost |
| `docs/costs.md` | per-session cost table |
| `docs/teardown.md` | teardown guarantees and sweep semantics |

Conventions (region, naming, address plan, tags) live in
[docs/walkthroughs/STRAYLIGHT-REFERENCE.md](../docs/walkthroughs/STRAYLIGHT-REFERENCE.md).
CI compiles and lints every `.bicep` file (no cloud auth, nothing deployed);
`verify`/`check` runs against real Azure are always manual.
