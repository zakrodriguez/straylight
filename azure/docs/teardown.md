# Teardown guarantees

Defense in depth, in order of actual protection:

1. **Teardown is a lab step.** Every walkthrough ends with
   `az700.sh destroy <slug>`, annotated for walkverify — a lab is not complete
   (or verifiable) without it.
2. **Stale-object preflight.** `az700.sh deploy` lists any surviving
   `rg-straylight-az700-*` group and requires confirmation before stacking a
   second lab on top of a forgotten one.
3. **Sweep.** `az700.sh sweep` (manual habit, or the optional
   [nightly timer](../scripts/systemd/README.md)) reports groups older than
   8 hours and can delete them.
4. **Budget alert — a backstop, not a brake.** `init` creates a $25/month
   budget with 50/80/100% email alerts. Azure budgets **alert, they do not
   stop spend**; if an alert fires, run `az700.sh nuke`.
5. **SKU floors in the Bicep modules.** The expensive failure modes are
   structurally impossible: no ExpressRoute/Firewall-Standard/DDoS resources
   exist in any topology, gateways and VMs are `@allowed`-pinned to the cheap
   SKUs.

## Scoping of destructive commands

`destroy`, `sweep --delete`, and `nuke` match resource groups by **name prefix
`rg-straylight-az700-` AND tag `track=az700`** (both, always) and re-check the
tag per group before deleting. Nothing else in the subscription can be
touched, whatever it is named.

Audit at any time:

```bash
az group list --tag track=az700 -o table   # ground truth
azure/scripts/az700.sh list                # + local claims (~/.straylight/az700-deployments.json)
```

The claims file is a local convenience mirror; Azure is authoritative. A
mid-delete crash can leave a claim behind — `az700.sh list` shows both so the
drift is visible.

## Known limits

- `az group delete --no-wait` returns before the gateway is actually gone;
  billing stops when deletion completes (minutes later). Use `destroy --wait`
  when you want confirmation.
- The sweep timer needs a logged-in az CLI; device-code tokens refresh for
  ~90 days, after which the sweep fails silently until the next `az login`
  (the timer's journal shows it: `journalctl --user -u az700-sweep`).
- On offer types where the budget API is unsupported, `init` prints portal
  instructions instead — create the budget by hand.
