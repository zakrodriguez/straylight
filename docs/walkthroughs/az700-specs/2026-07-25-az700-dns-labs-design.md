# AZ-700 DNS Labs — Design

**Date:** 2026-07-25
**Companion to:** MS Learn AZ-700 learning path, *Design and implement name
resolution* (Azure DNS public zones, private zones and auto-registration,
DNS Private Resolver)
**Predecessor pattern:** `2026-07-18-az700-vnet-labs-design.md` (vnet module;
graduated v2.10.0)

## Goal

Second module of the AZ-700 track: name resolution. Two hands-on labs now —
private DNS zones (with virtual-network links and auto-registration) and
public DNS zones (records, TTL, and alias records) — plus quizzes and the
module exam. The module's third lab, **DNS Private Resolver, is deferred to
after the hybrid module**: its whole point is conditional forwarding between
on-prem and Azure, which needs the S2S tunnel standing (plan: `az700-hybrid`).
The exam covers the full name-resolution blueprint, including resolver
concepts, so it ships now; the resolver lab joins the module later.

Everything runs from the host (`walkverify host=lab`); no Straylight VMs are
involved (`azure-only`).

## MS Learn → lab mapping

| MS Learn topic (Design and implement name resolution) | Lab |
|---|---|
| Private DNS zones, virtual-network links, auto-registration | `az700-dns-1-private-zones-walkthrough.md` |
| Public DNS zones, record sets, TTL, alias records | `az700-dns-2-public-zones-alias-walkthrough.md` |
| DNS Private Resolver (inbound/outbound endpoints, rulesets) | deferred — lands with the hybrid module |

Net new: 2 labs + 2 quizzes + this spec + the module exam.

## Deploy contract (locked)

**Both labs reuse the `hub-spoke` topology** — no new Bicep. The plan
sketched a dedicated `labs/dns/` topology, but hub-spoke already provides
everything these labs consume (three VNets to link zones to, `vm-spoke1` for
auto-registration and in-VNet resolution probes), and every DNS resource
(zones, links, record sets, the alias-target public IP) is created by lab
steps inside the same resource group — so they die with the RG on teardown,
same as the vnet module's hand-made resources. A dedicated topology would
add maintenance surface and deploy time for nothing. (`labs/dns-private-resolver/`
still arrives with the deferred lab 3 — a resolver is a deployed resource,
not a lab step.)

| Lab | Topology (`azure/labs/<slug>`) | What the deploy provides | What the lab creates by hand |
|---|---|---|---|
| 1 | `hub-spoke` | RG + hub/spoke1/spoke2 VNets + `vm-spoke1` (B2ts_v2) | private zone `internal.straylight.example`, registration + resolution VNet links, a static A record; reads auto-registered records; probes resolution from `vm-spoke1` |
| 2 | `hub-spoke` | same (only the RG and `vm-spoke1` matter) | public zone `straylight.example`, A/CNAME record sets, `pip-dnslab` + an alias A record targeting it; probes the zone's Azure name servers with `dig` |

Labs 1–2 share one `deploy hub-spoke` session (Before-you-start says so);
each lab remains self-contained: Setup prechecks the deployment, the final
annotated step is `az700.sh destroy hub-spoke` (lab 1 carries the
"continuing? skip teardown" note).

Zone names use the RFC 2606 reserved TLD: public `straylight.example`,
private `internal.straylight.example` — deliberately split-horizon-shaped.
Neither is delegated anywhere; lab 2 queries the zone's assigned Azure name
servers directly, which works without owning the name.

## Cost table (locked)

| Lab | Metered pieces | Session estimate |
|---|---|---|
| 1 | 1 × B2ts_v2; private zone ~$0.50/mo prorated (~$0.002/day); queries negligible | < $0.25 |
| 2 | 1 × B2ts_v2; public zone same band; one Standard public IP ~$0.004/hr | < $0.25 |
| Both, one sitting | | **< $0.30** |

## Verification model

Same as the vnet module, plus lessons from its verification session:

- Asserted steps project with `--query <JMESPath> -o tsv`; az prints tsv
  booleans **lowercase** (`true`/`false`) and expects are written lowercase.
- Public-facing values (the alias public IP, documentation IPs like
  `203.0.113.10`, Azure NS hostnames) get masked by the `pubip` normalizer —
  every expect on such output accepts `<PUBIP>` as an alternative.
- Auto-registration back-fill for a pre-existing VM is not instantaneous:
  the assertion is a bounded poll (240 s in-block, under walkverify's 300 s
  step cap), not a single read.
- Capture/check runs use `--vagrant-root <repo root>` (host=lab cwd rule;
  see the vnet spec).
- Both labs target **VERIFIABLE**; Azure `verify`/`check` replays stay
  manual-only.

## Non-goals

- No zone delegation to a registrar (nothing here owns a real domain; the
  delegation workflow is prose + exam material).
- No custom DNS servers on the VNet and no DNS Private Resolver deployment —
  resolver concepts are exam material now, hands-on after the hybrid module.
- No DNSSEC (in preview on public zones; not exam-relevant at this depth).
