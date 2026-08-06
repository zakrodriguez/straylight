# AZ-700 LB Lab 3 — Web Application Firewall

A Web Application Firewall is not a load balancer — it is the **rule engine
that rides one**. On Azure it attaches to **Application Gateway** (the
`WAF_v2` tier) or to **Front Door**, and inspects every HTTP request against
the OWASP Core Rule Set before the request reaches your backend. This lab is a
**runbook**: WAF behaviour is signature- and latency-dependent and the `WAF_v2`
tier is pricier than the Standard_v2 gateway from Lab 2, so rather than assert
live blocks, it teaches the policy model against the `appgw` topology and shows
exactly what changes to turn the firewall on.

Pairs with MS Learn: *Design and implement application delivery* — Web
Application Firewall (AZ-700 learning path).

> **Runbook lab (no walkverify golden)**. Commands are shown with the shapes to
> expect, not asserted. Turning on WAF means the **WAF_v2** gateway tier
> (~$0.36/hr) — deploy it only for hands-on reps, and destroy the same day.

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Lab 2's concepts (gateway, listener, routing) | WAF is a policy attached to that gateway |
| az CLI ≥ 2.60, logged in | commands are `az` from the host |
| Verification: RUNBOOK (no golden, no `@verify`) | live WAF blocks are signature/latency-dependent, not a CI/gate step |

## The model, before the commands

A WAF on Azure is two things bound together:

1. A **WAF policy** (`Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies`)
   — the rules and settings.
2. An **association** — the policy attached to a gateway, a listener, or a
   path — and the gateway running the **WAF_v2** tier so it can enforce.

Inside the policy:

- **Managed rule set** — the **OWASP Core Rule Set** (CRS 3.2 is current;
  DRS on Front Door). These are Microsoft-maintained signatures for SQL
  injection, XSS, RCE, protocol violations, and so on. You pick the version
  and can disable individual rules or groups.
- **Custom rules** — your own match conditions (by IP, geo, header, query
  string, size) with an action, evaluated **before** the managed set and in
  **priority** order. Rate-limiting is a custom-rule type.
- **Mode** — the single most important WAF setting:
  - **Detection** — logs what *would* have been blocked, blocks nothing.
    Always start here; it is how you find false positives before they break
    real users.
  - **Prevention** — actually blocks matching requests (403). Flip to this
    only after Detection shows the ruleset is clean for your app.
- **Exclusions** — attributes to skip (a header or cookie your app legitimately
  sends that trips a rule), so you can stay in Prevention without disabling a
  whole rule for everyone.

## Runbook — create a WAF policy in Detection mode

```bash
RG=rg-straylight-az700-appgw

# A policy starts in Detection with the managed OWASP CRS attached.
az network application-gateway waf-policy create --resource-group $RG \
  --name wafpol-straylight
az network application-gateway waf-policy policy-setting update \
  --resource-group $RG --policy-name wafpol-straylight \
  --state Enabled --mode Detection
#   Read it back:
az network application-gateway waf-policy show --resource-group $RG \
  --name wafpol-straylight \
  --query "{state:policySettings.state, mode:policySettings.mode, managed:managedRules.managedRuleSets[0].ruleSetType}" -o json
#   Expect: state Enabled, mode Detection, managed OWASP
```

## Runbook — a custom rule (block a country, rate-limit)

```bash
RG=rg-straylight-az700-appgw

# Custom rules run before the managed set, in priority order. Example: block
# requests whose source geo is a given country code.
az network application-gateway waf-policy custom-rule create \
  --resource-group $RG --policy-name wafpol-straylight \
  --name blockGeo --priority 10 --rule-type MatchRule --action Block
az network application-gateway waf-policy custom-rule match-condition add \
  --resource-group $RG --policy-name wafpol-straylight --name blockGeo \
  --match-variables RemoteAddr --operator GeoMatch --values KP
#   Rate-limiting is a RateLimitRule custom rule (requests per minute per IP).
```

## Runbook — turn it on: WAF_v2 tier + associate

WAF only enforces on a **WAF_v2** gateway. On the Lab 2 gateway that means
changing the SKU tier and attaching the policy:

```bash
RG=rg-straylight-az700-appgw

# Flip the gateway tier to WAF_v2 and attach the policy (this reprovisions —
# ~15-20 min, and the tier now meters higher).
az network application-gateway update --resource-group $RG --name agw-straylight \
  --sku WAF_v2 \
  --set "firewallPolicy.id=$(az network application-gateway waf-policy show \
        -g $RG -n wafpol-straylight --query id -o tsv)"

# Only once Detection logs are clean for your app, move to Prevention:
az network application-gateway waf-policy policy-setting update \
  --resource-group $RG --policy-name wafpol-straylight --mode Prevention
```

Blocked and matched requests land in the **`ApplicationGatewayFirewallLog`**
(Log Analytics / diagnostic settings) — that log is where you tune Detection
before ever enabling Prevention.

## Where a WAF belongs (the exam framing)

- **App Gateway WAF_v2** — regional Layer-7 apps; the WAF sits at the regional
  entry point (this lab).
- **Front Door WAF** — global apps; the WAF sits at the Microsoft **edge**, so
  bad requests are dropped closer to the client, before they cross a region
  (Lab 5). The rule model is the same idea (managed DRS + custom rules,
  Detection/Prevention).
- **Both** — edge WAF on Front Door for global filtering *and* a regional WAF
  on App Gateway for defense in depth is a valid, common design.

## What you learned (runbook)

- A WAF is a **policy** (managed OWASP CRS + custom rules + mode + exclusions)
  **associated** to a gateway/listener/path, enforced by the **WAF_v2** tier.
- **Detection first, Prevention after** — Detection logs would-be blocks so you
  clear false positives before breaking real traffic; exclusions let you stay
  in Prevention without disabling a rule globally.
- **Custom rules run before** the managed set, in priority order; rate-limiting
  is a custom-rule type.
- WAF attaches to **App Gateway (regional)** or **Front Door (global/edge)** —
  same model, different place in the path.
