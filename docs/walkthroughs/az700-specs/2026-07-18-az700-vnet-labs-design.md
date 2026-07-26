# AZ-700 VNet Labs — Design

**Date:** 2026-07-18
**Companion to:** MS Learn AZ-700 learning path, *Introduction to Azure
virtual networks* (plan VNets/IP addressing, virtual network peering, custom
routes/NVA, Virtual Network NAT)
**Predecessor pattern:** `../specs/2026-05-12-adcs-functest-labs-design.md`
(adcs-functest module — the PKI catalog's design pattern; this spec opens
the AZ-700 track)

## Goal

First module of the AZ-700 track: core virtual networking. The MS Learn
module teaches the concepts; each lab makes the operator type the real `az`
invocations against a disposable deployment and read the actual output —
same 1:1 guide↔lab contract as the PKI catalog, with MS Learn in the
external-guide slot.

Everything runs from the host (`walkverify host=lab`): no Straylight VMs are
involved in this module (`azure-only`). Azure resources come from
`azure/scripts/az700.sh deploy <slug>` and die with `destroy <slug>` the same
day.

## MS Learn → lab mapping

| MS Learn topic (Intro to Azure virtual networks) | Lab |
|---|---|
| Plan VNets, subnets, IP addressing; reserved addresses/names | `az700-vnet-1-address-space-subnets-walkthrough.md` |
| Configure virtual network peering; hub-spoke; transitivity | `az700-vnet-2-peering-hub-spoke-walkthrough.md` |
| System vs custom routes, UDRs, routing through an NVA | `az700-vnet-3-routing-udr-nva-walkthrough.md` |
| Outbound connectivity with Virtual Network NAT | `az700-vnet-4-nat-gateway-walkthrough.md` |

Net new: 4 labs + 4 quizzes + this spec + one module exam.

## Deploy contract (locked)

| Lab | Topology (`azure/labs/<slug>`) | What the deploy provides | What the lab creates by hand |
|---|---|---|---|
| 1 | `hub-spoke` | RG + hub/spoke1/spoke2 VNets + `vm-spoke1` (B2ts_v2) | a scratch VNet (`vnet-lab1`, 10.103.0.0/24) + subnets, deleted in-lab |
| 2 | `hub-spoke` | same (spokes deliberately **unpeered**) | all four peerings; reads `vm-spoke1` effective routes |
| 3 | `hub-spoke` | same | NVA VM (B2ts_v2, IP forwarding) + route table + UDR |
| 4 | `nat-gateway` | RG + `vnet-nat` (`defaultOutboundAccess:false`) + `vm-nat1` | NAT gateway + public IP + subnet association |

Labs 1–3 are written to run back-to-back against one `deploy hub-spoke`
(the Before-you-start note says so); each lab is nonetheless self-contained:
its Setup prechecks the deployment and its final annotated step is
`az700.sh destroy <slug>` (with a "continuing? skip teardown" note).

## Cost table (locked; bands re-checked 2026-07-25 on the live verification run)

| Lab | Metered pieces | Session estimate |
|---|---|---|
| 1 | 1 × B2ts_v2; VNets/subnets free | < $0.25 |
| 2 | 1 × B2ts_v2; peerings ~free at lab traffic volume | < $0.25 |
| 3 | 2 × B2ts_v2 (test + NVA) | < $0.50 |
| 4 | 1 × B2ts_v2 + NAT GW ~$0.045/hr + PIP | < $0.30 |
| Whole module, one sitting | | **< $1** |

## Verification model

- Every asserted step projects with `--query <JMESPath> -o tsv` — small
  deterministic strings (`Succeeded`, `Connected`, a prefix), never raw JSON.
- All four labs target **VERIFIABLE** (lint + approved golden + manual
  `check`). Azure `verify`/`check` runs are manual-only — each replay costs
  real money; cadence is pre-graduation + az CLI major bumps.
- Goldens pin the az CLI version in `parameters:` and must normalize
  subscription GUIDs and public IPs (`<GUID>`, `<PUBIP>`) before commit.
- Deliberate-failure demonstrations (overlapping subnets, spoke→spoke before
  peering) stay **unannotated** prose with an "Expected: error …" comment —
  az error text varies by CLI version and asserting on it would make `check`
  flaky.
- Capture/check invocation (learned 2026-07-25): run walkverify with
  `--vagrant-root <repo root>` for azure-only labs. `host=lab` steps execute
  with cwd = vagrant-root, and each lab's teardown block calls the
  repo-root-relative `azure/scripts/az700.sh` — under the default
  vagrant-root (`vagrant/`) that path exits 127 and the teardown silently
  never runs.

## Non-goals

- No IPv6, no subnet delegation, no ddos/bastion deployments (cost); named
  in prose + quizzes only.
- No portal steps: this module is CLI-first (the exam's hotspot questions
  quiz portal blades; the quizzes and module exam cover that angle).
- Not touched: `vnet-hub`'s GatewaySubnet stays empty — gateways belong to
  the `az700-hybrid` module.
