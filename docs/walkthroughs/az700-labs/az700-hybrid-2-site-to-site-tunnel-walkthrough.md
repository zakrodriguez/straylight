# AZ-700 Hybrid Lab 2 — The Site-to-Site Tunnel, End to End

Lab 1 built the four Azure resources and left the connection
`NotConnected` — a patient responder. This lab brings up the on-prem
initiator, watches IKEv2 negotiate and the tunnel install, and then proves
the thing that actually matters: a host on your lab network reaches a
private IP inside Azure, and vice versa, with no public exposure. This is
the flagship of the whole track — the moment the Straylight lab and Azure
become one routed network over an encrypted tunnel across the public
internet.

Pairs with MS Learn: *Design and implement hybrid connectivity* —
site-to-site VPN and IKEv2 (AZ-700 learning path).

> **Before you start**: Lab 1's gateway must be up (`az700.sh watch
> hybrid-vpn` shows Succeeded, and the idempotent re-deploy recorded the
> gateway public IP). Then bring up the on-prem side and load the tunnel:
>
> ```bash
> cd vagrant && LAB_PROFILE=az700-hybrid ./up.sh    # dc1 + vpn1 (~25 min; dc1 promo)
> # vpn1 reads ~/.straylight/az700/hybrid-vpn.env and renders the tunnel.
> # If vpn1 was built BEFORE the gateway IP was recorded, re-provision it:
> #   LAB_PROFILE=az700-hybrid VAGRANT_DOTFILE_PATH=.vagrant-az700-hybrid vagrant provision vpn1
> ```
>
> **Cost**: no new metered Azure resource — the gateway from Lab 1 is
> already running. Continue straight from Lab 1.
> **Teardown**: Lab 3, Step 6 (`destroy hybrid-vpn` + nuke the on-prem VMs).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| Lab 1 gateway Succeeded + public IP recorded | the on-prem side dials that address |
| `LAB_PROFILE=az700-hybrid` up (dc1 + vpn1) | vpn1 is the initiator; dc1 is the on-prem host that routes to Azure |
| `~/.straylight/az700/hybrid-vpn.env` complete (gateway IP + on-prem IP + PSK) | vpn1's `strongswan_azure` role renders the tunnel from it |
| Verification: VERIFIABLE (walkverify golden, live-capture) | `swanctl`/`ping` on vpn1, `az` on the host, `Get-NetRoute` on dc1 |

## Step 1 — Initiate and confirm the security association

`vpn1` runs strongSwan with `start_action = start`, so charon initiates on
load. Confirm the IKE SA established. On `vpn1`:

<!-- @verify host=vpn1 step=ike-established expect=/ESTABLISHED/ rc=0 -->
```bash
sudo swanctl --initiate --child azure 2>/dev/null || true
sudo swanctl --list-sas
# Expected: azure: #N, ESTABLISHED, IKEv2, ...
#           azure: #M, reqid 1, INSTALLED, TUNNEL, ESP:AES_CBC-256/HMAC_SHA2_256_128
```

`ESTABLISHED` on the IKE SA and `INSTALLED` on the child SA is the
authoritative "the tunnel is up" signal — it is the on-prem end of the
negotiation, and it is true the instant crypto agrees, well before Azure's
control-plane status catches up (Step 4).

> **If this shows `NO_PROPOSAL_CHOSEN` instead:** the crypto policies don't
> match. This is exactly what Azure's *default* policy produced against
> strongSwan on VpnGw1AZ. The fix — already baked into this lab's
> connection (Lab 1, Step 4) — is an explicit, identical IPsec/IKE policy
> pinned on both ends: AES256/SHA256/DHGroup14 for IKE, AES256/SHA256 with
> no PFS for ESP. When you see a proposal error on a route-based tunnel,
> stop trusting defaults and pin.

## Step 2 — Read the traffic selectors

The child SA carries **traffic selectors** — the local and remote prefixes
the tunnel actually encrypts. These come from the on-prem side's config
(the lab supernet) and the LNG address space (the Azure pool). On `vpn1`:

<!-- @verify host=vpn1 step=traffic-selectors expect=/192\.168\.56\.0/ expect=/10\.100\.0\.0/ rc=0 -->
```bash
# Match only the child-SA selector lines (the CIDR prefixes), not the IKE
# endpoint lines (those carry the public IPs).
sudo swanctl --list-sas | grep -E '192\.168\.56\.0|10\.100\.0\.0'
# Expected:
#   local  192.168.56.0/21     <- the lab's host-only supernet (on-prem)
#   remote 10.100.0.0/14        <- the Azure-side pool (hub + all spokes)
```

These two prefixes are the entire scope of what the tunnel carries. A
packet whose source and destination don't both fall inside this pair is
never encrypted into the tunnel — which is why the address plan
(`192.168.56.0/21` on-prem, `10.100.0.0/14` Azure) had to be pinned
module-wide: the selectors are derived from it, and a mismatch here is a
silent "tunnel up, no traffic" failure.

## Step 3 — Reach Azure from on-prem

The real test: a packet from the lab network to a private IP inside Azure,
over the tunnel. `vm-hub1` sits in the hub's `snet-shared` (10.100.2.0/24)
and takes the first dynamic address, `10.100.2.4`. From `vpn1`:

<!-- @verify host=vpn1 step=onprem-to-azure expect=/0% packet loss/ rc=0 -->
```bash
ping -c 4 -W 3 10.100.2.4
# Expected: 4 packets transmitted, 4 received, 0% packet loss
#           (RTT is your home round-trip to centralus — ~40 ms is typical)
# If vm-hub1 got a different address: az vm list-ip-addresses -g
#   rg-straylight-az700-hybrid-vpn -n vm-hub1 --query
#   "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv
```

Those ICMP replies came back *from inside Azure*, across an encrypted
tunnel, over your residential uplink. The Azure VM has no public IP — it is
reachable only because the S2S selectors carry `192.168.56.0/21 ⇔
10.100.0.0/14` and the gateway routes the reply back down the tunnel.

## Step 4 — Confirm the Azure side agrees

Now check the Azure control plane. On the host:

<!-- @verify host=lab step=azure-connected expect=/Connected/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vpn-connection show --resource-group $RG --name cn-straylight-s2s \
  --query "{status:connectionStatus, ingress:ingressBytesTransferred, egress:egressBytesTransferred}" -o json
# Expected: connectionStatus Connected, non-zero bytes each way
```

> **Azure's status lags the data plane by minutes.** The tunnel carries
> traffic (Step 3 proved it) before `connectionStatus` flips from
> `NotConnected` to `Connected` and the byte counters populate — Azure
> updates this field from gateway telemetry on its own cadence. The
> `swanctl` SA state (Step 1) and an actual ping (Step 3) are the
> authoritative signals; this step is the lagging confirmation. If it still
> reads `NotConnected` right after the ping succeeds, wait a minute and
> re-run — do not tear anything down.

## Step 5 — Route the whole on-prem site through the tunnel

`vpn1` is the tunnel endpoint, but the rest of the lab reaches Azure only
if it *routes* there. The `azure_routes` role gives dc1 a persistent route
for the Azure pool pointing at vpn1, and vpn1 forwards it into the tunnel.
On `dc1`:

<!-- @verify host=dc1 step=dc1-route-to-azure expect=/True/ rc=0 -->
```powershell
# The persistent route for the Azure pool points at vpn1
(Get-NetRoute -DestinationPrefix '10.100.0.0/14' -ErrorAction SilentlyContinue |
    Select-Object -First 1).NextHop
# Expected: vpn1's lab IP (e.g. 192.168.5x.45)

# And dc1 can actually reach the Azure VM through it
Test-NetConnection 10.100.2.4 -InformationLevel Quiet
# Expected: True
```

`dc1` has no tunnel of its own and no Azure knowledge — it simply sends
Azure-bound packets to vpn1 (per the route), and vpn1 forwards them into
the SA. That is the whole point of a site-to-site VPN: one tunnel endpoint,
and the entire on-prem site rides it. Every present and future lab host
that carries the `azure_routes` route reaches Azure the same way, with no
per-host VPN configuration.

## What you proved

- The **`swanctl` SA state** (`ESTABLISHED` + `INSTALLED`) is the
  authoritative tunnel-up signal — true the moment crypto agrees, ahead of
  Azure's lagging `connectionStatus`.
- **Traffic selectors** (`192.168.56.0/21 ⇔ 10.100.0.0/14`) define exactly
  what the tunnel encrypts; a mismatch is a silent no-traffic failure,
  which is why the module pins the address plan.
- A `NO_PROPOSAL_CHOSEN` failure is a crypto-policy mismatch — pin an
  explicit, identical IPsec/IKE policy on both ends.
- On-prem reaches Azure private IPs over the tunnel with no public
  exposure, and the **whole site routes through one endpoint** via a
  static route to vpn1 — no per-host VPN config.
