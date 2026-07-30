# AZ-700 Module Exam — Hybrid Connectivity (Site-to-Site VPN & BGP)

**Module:** az700-hybrid (Labs 1–3 hands-on; point-to-site, Virtual WAN, and
ExpressRoute examined here, hands-on/paper labs arrive with P3b).
**Format:** 24 questions in three sections — gateway anatomy (1–8),
site-to-site tunnel (9–16), BGP and design (17–24). Mixed multiple-choice
and short answer.
**Suggested time:** 45–60 minutes, closed book.

---

## Section 1 — VPN gateway anatomy

**Q1.** Name the four resources that make up a site-to-site VPN and each
one's responsibility.

(short answer)

---

**Q2.** Which VPN gateway type uses IKEv2 and supports BGP?

a) Policy-based
b) Route-based
c) Both
d) Neither — BGP needs ExpressRoute

---

**Q3.** What does the `AZ` in `VpnGw2AZ` guarantee, and what does it require
of the gateway's public IP?

(short answer)

---

**Q4.** True/false with reason: the local network gateway is a running
Azure resource that terminates the on-prem end of the tunnel.

(short answer)

---

**Q5.** A connection shows `connectionStatus: NotConnected` immediately
after deploy, before any on-prem configuration. Is this a problem?

(short answer)

---

**Q6.** The GatewaySubnet: what is special about its name, and what must it
*not* have attached?

(short answer)

---

**Q7.** A route-based S2S tunnel fails at IKE_SA_INIT with a proposal
error, and both ends "look right". What is the most reliable fix?

a) Reboot the on-prem VPN device
b) Switch to policy-based
c) Pin an explicit, identical IPsec/IKE policy on both ends
d) Open more ports on the firewall

---

**Q8.** Why can Basic SKU never be used for a design that needs BGP or
active-active?

(short answer)

---

## Section 2 — Site-to-site tunnel

**Q9.** `swanctl` shows `ESTABLISHED`; Azure shows `NotConnected`. Tunnel
up or down? Which signal wins?

(short answer)

---

**Q10.** Define traffic selectors. Give the two prefixes on the Straylight
tunnel and explain a selector-mismatch failure.

(short answer)

---

**Q11.** In the lab-as-on-prem design, which side initiates? Give the
concrete home-networking reason it must be that side.

(short answer)

---

**Q12.** `vpn1` reaches an Azure private IP; `dc1` on the same LAN does
not. Fix?

a) Give dc1 its own tunnel
b) A route for the Azure pool via vpn1 (the `azure_routes` role)
c) A public IP on dc1
d) Enable BGP

---

**Q13.** An Azure VM with no public IP answers a ping from the on-prem
lab. Explain the path in terms of selectors and the gateway.

(short answer)

---

**Q14.** After the tunnel is up and traffic has flowed, `connectionStatus`
still reads `NotConnected`. Correct action?

a) Redeploy the gateway
b) Recreate the connection
c) Wait — it's control-plane lag
d) Restart strongSwan

---

**Q15.** Your router's public IP changes (dynamic ISP). The tunnel drops.
What Azure object is now wrong, and what refreshes it?

(short answer)

---

**Q16.** How many VPN configurations does adding a second on-prem host to
the site require, and why?

(short answer)

---

## Section 3 — BGP and design

**Q17.** What does BGP eliminate on a S2S VPN, and name two capabilities
that require it.

(short answer)

---

**Q18.** By default (single active-passive gateway), the on-prem BGP
speaker peers with which address on the Azure gateway?

a) The gateway's public IP
b) The gateway's GatewaySubnet IP (defaultBgpIpAddresses)
c) An APIPA (169.254.x.x) address — always
d) 168.63.129.16

---

**Q19.** Azure's default gateway ASN, the reserved ASN range, and a valid
private ASN for the on-prem side.

(short answer)

---

**Q20.** BGP won't establish over the tunnel; the neighbor is APIPA. What
FRR setting is typically required and why?

(short answer)

---

**Q21.** With BGP running, you add a spoke VNet in Azure. What must change
on the on-prem LNG?

a) Add the new prefix to the LNG address space
b) Nothing — BGP advertises it
c) Recreate the connection
d) Add a static route on every on-prem host

---

**Q22.** What transport does the BGP session use, and where does it run
relative to the IPsec tunnel?

(short answer)

---

**Q23.** Point-to-site vs site-to-site: one sentence each on when you'd
choose which.

(short answer)

---

**Q24.** Design scenario: two branch offices, both need connectivity to an
Azure hub and automatic failover between two Azure gateway instances.
Name the three features this requires (gateway mode, routing protocol, and
one gateway capability), in one line each.

(short answer)

---

## Answers

### Section 1

**Q1.** Virtual network gateway (Azure VPN endpoint, in GatewaySubnet);
public IP (dialed by on-prem); local network gateway (on-prem site
description: public IP + address space); connection (PSK + IKEv2 + IPsec
policy binding the two).

**Q2.** **b)** Route-based.

**Q3.** Zone redundancy (gateway spans availability zones); requires a
zone-redundant Standard static public IP.

**Q4.** **False.** The LNG is a *description* of the remote site (on-prem
public IP + address space), not a running resource; the on-prem device
terminates the tunnel.

**Q5.** No — the Azure gateway is the responder; it stays `NotConnected`
until an on-prem peer initiates.

**Q6.** `GatewaySubnet` is a reserved name — a VPN/ER gateway only deploys
into a subnet named exactly that; it must **not** carry an NSG.

**Q7.** **c)** Pin an explicit, identical IPsec/IKE policy on both ends.

**Q8.** Basic SKU has no BGP, no active-active, no zone redundancy — the
capabilities aren't present in the SKU, so no configuration enables them.

### Section 2

**Q9.** **Up.** The `swanctl` SA state wins — it's the data-plane truth;
Azure's status lags by minutes.

**Q10.** The local/remote prefixes the tunnel encrypts: `192.168.56.0/21` ⇔
`10.100.0.0/14`. A packet not matching both selectors isn't encrypted into
the tunnel — a silent "up but no traffic" failure.

**Q11.** vpn1 (on-prem) initiates. Behind VBox NAT + a home router it only
needs outbound UDP/500+4500, so no inbound port-forward is required; NAT-T
carries it.

**Q12.** **b)** A route for the Azure pool via vpn1.

**Q13.** Source (on-prem) and destination (Azure private IP) both match the
selectors, so vpn1 encrypts into the tunnel; the gateway decrypts and
delivers inside the VNet, and routes the reply back down the tunnel — no
public IP involved.

**Q14.** **c)** Wait — control-plane lag.

**Q15.** The **local network gateway**'s `gatewayIpAddress` is now stale;
`az700.sh update-onprem-ip hybrid-vpn` (or `az network local-gateway
update --gateway-ip-address`) refreshes it.

**Q16.** Zero — every host with the route to the Azure pool via vpn1
reaches Azure through the single tunnel endpoint; no per-host VPN config.

### Section 3

**Q17.** It eliminates static LNG address-space maintenance (dynamic route
exchange). Requires: active-active gateways, multi-site failover,
ExpressRoute/VPN coexistence (any two).

**Q18.** **b)** The gateway's GatewaySubnet IP (`defaultBgpIpAddresses`).
APIPA (`customBgpIpAddresses`) is the active-active / opt-in case, not the
default.

**Q19.** Default ASN **65515**; reserved **65515–65520**; valid private ASN
from **64512–65534** (e.g. 65050).

**Q20.** `ebgp-multihop` (≈2) — the APIPA peer isn't directly on-link over
the tunnel, so single-hop eBGP can't reach it (or add a static route to the
APIPA peer via the tunnel).

**Q21.** **b)** Nothing — BGP advertises it.

**Q22.** TCP/179, running **inside** the IPsec tunnel (its packets match
the selectors and are encrypted); the tunnel is the transport, so it must
be up first.

**Q23.** Point-to-site: individual clients/devices dialing in (remote
workers, no on-prem gateway). Site-to-site: a whole network/site connected
via an on-prem VPN device.

**Q24.** **Active-active gateway mode** (two instances for failover);
**BGP** (dynamic routing + failover convergence); a **route-based, AZ SKU
gateway** (only these support active-active + BGP + zone redundancy).

</details>
