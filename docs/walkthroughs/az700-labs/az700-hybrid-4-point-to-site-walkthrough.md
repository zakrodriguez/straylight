# AZ-700 Hybrid Lab 4 — Point-to-Site VPN

Site-to-site (Labs 1–3) connects a **network** to Azure. Point-to-site
connects a **single client** — a laptop, a developer's machine — to the same
VNet, over its own per-client tunnel, with no on-prem gateway involved. It
rides the **same virtual network gateway** you already deployed: P2S is not a
new resource, it is a **profile you add to the gateway** (a client address
pool, a tunnel protocol, and an authentication model). This lab configures
that profile by hand — because configuring P2S *is* the exam skill — reads it
back, and clears it before teardown so the S2S labs' gateway is left as it
was.

Pairs with MS Learn: *Design and implement hybrid connectivity* — configure
point-to-site VPN (AZ-700 learning path).

> **Before you start**: this lab reuses the **standing `hybrid-vpn`
> gateway** from Labs 1–3 — do not deploy anything new. If the gateway is
> already up (you are running the module in one sitting), continue straight
> in. If you tore it down, bring it back:
>
> ```bash
> azure/scripts/az700.sh deploy hybrid-vpn --no-wait
> azure/scripts/az700.sh watch hybrid-vpn      # ~21 min if freshly deployed
> ```
>
> **Cost**: P2S adds **no metered resource** — the gateway you are already
> paying for carries it. **Teardown**: this lab's last step clears the P2S
> profile; destroy the gateway itself with `azure/scripts/az700.sh destroy
> hybrid-vpn` when you finish the module (Lab 5 does not use it).

## Lab requirements

| Requirement | Why it matters |
|---|---|
| `hybrid-vpn` gateway provisioned (`watch` shows Succeeded) | P2S is a profile on this existing gateway |
| `openssl` on the host | the certificate auth model needs a self-signed root |
| az CLI ≥ 2.60, logged in | every step is `az` from the host |
| Verification: VERIFIABLE (config-level; golden live-capture) | asserts the P2S profile via `--query`; the client *connect* is a runbook note (Windows/OpenVPN-client task) |

## Setup (one-time, idempotent)

Confirm the gateway is there and route-based (P2S requires route-based):

<!-- @verify host=lab step=deploy-precheck expect=/RouteBased/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vnet-gateway show --resource-group $RG --name vpngw-hub \
  --query vpnType -o tsv
# Expected: RouteBased   (policy-based gateways cannot do P2S)
```

## Step 1 — Mint a self-signed root certificate (Azure-certificate auth)

The **Azure certificate** auth model trusts a **root certificate** you upload;
clients present a leaf signed by that root. Mint the root on the host:

<!-- @verify host=lab step=make-root expect=/P2SRootCert/ rc=0 -->
```bash
WORK=$(mktemp -d)
openssl genpkey -algorithm RSA -out "$WORK/root.key" 2>/dev/null
openssl req -x509 -new -nodes -key "$WORK/root.key" -days 365 \
  -subj "/CN=P2SRootCert" -out "$WORK/root.crt" 2>/dev/null
# Azure wants the DER bytes, base64, single line. `root-cert create` reads
# --public-cert-data as a FILE PATH (that arg is always resolved as a path,
# never inline), so write the base64 to a file for the next step:
openssl x509 -in "$WORK/root.crt" -outform der | base64 -w0 > "$WORK/root.b64"
echo "$WORK" > /tmp/p2s-work-dir
openssl x509 -in "$WORK/root.crt" -noout -subject | grep -o P2SRootCert
# Expected: P2SRootCert   (the root exists; $WORK/root.b64 holds its base64 form)
```

In production this root lives in your PKI (the Straylight lab's own AD CS
could issue it); the P2S trust chain is exactly a normal cert chain, which is
why this module and the PKI labs meet here.

## Step 2 — Enable the P2S profile (address pool + protocols)

Set the **client address pool** and the **tunnel protocols** on the gateway.
This is a gateway update — it blocks until applied (a few minutes). The pool
must not overlap the VNet (`10.100.0.0/14`) or the on-prem space
(`192.168.56.0/21`); `172.16.201.0/24` is the reserved `p2sPool`
(`naming.bicep`).

<!-- @verify host=lab step=enable-p2s expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vnet-gateway update --resource-group $RG --name vpngw-hub \
  --address-prefixes 172.16.201.0/24 \
  --client-protocol OpenVPN IKEv2 \
  --query provisioningState -o tsv
# Expected: Succeeded   (the update blocks until the profile is applied)
```

- **OpenVPN + IKEv2** — OpenVPN (TLS, TCP/443-friendly) is the modern default
  and the only protocol that also supports **Microsoft Entra ID** auth;
  **IKEv2** (IPsec) covers native macOS/Windows clients. **SSTP** exists but
  is Windows-only and TCP/443, chosen only when OpenVPN can't be. Enable more
  than one and clients pick.
- **The address pool is Azure's, not on-prem's** — each connected client
  leases an address from `172.16.201.0/24`; that is why it must not collide
  with anything the tunnel already routes.

## Step 3 — Upload the root certificate

Add the Step 1 root to the gateway's trusted P2S roots. This is a second
gateway update; the gateway is idle after Step 2, so it runs cleanly (issuing
two gateway operations at once would conflict):

<!-- @verify host=lab step=add-root expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
WORK=$(cat /tmp/p2s-work-dir)
az network vnet-gateway root-cert create --resource-group $RG \
  --gateway-name vpngw-hub --name P2SRoot --public-cert-data "$WORK/root.b64" \
  --query provisioningState -o tsv
# Expected: Succeeded   (the root is now trusted for client certificates)
```

## Step 4 — Read the P2S profile back

<!-- @verify host=lab step=p2s-config expect=/172\.16\.201\.0/ expect=/OpenVPN/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
az network vnet-gateway show --resource-group $RG --name vpngw-hub \
  --query "vpnClientConfiguration.{pool:vpnClientAddressPool.addressPrefixes, protocols:vpnClientProtocols, roots:vpnClientRootCertificates[].name}" -o json
# Expected: pool ["172.16.201.0/24"], protocols include OpenVPN (and IKEv2),
#           roots ["P2SRoot"]
```

That JSON *is* the P2S profile — the same object the portal's "Point-to-site
configuration" blade edits. No connection object, no LNG: P2S has no on-prem
side to model.

## Step 5 — Generate a client profile package

Clients don't get hand-configured — the gateway **generates a profile
package** (the VPN client config, embedded with the gateway address and the
trusted root) that the OpenVPN or native client imports:

<!-- @verify host=lab step=gen-client expect=/blob.core.windows.net/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
# The generated URL carries a short-lived SAS token; strip the query string
# (?sv=...&sig=...) so only the package location is shown, never the secret.
az network vnet-gateway vpn-client generate --resource-group $RG \
  --name vpngw-hub --processor-architecture Amd64 -o tsv | sed 's/?.*//'
# Expected: https://<storage>.blob.core.windows.net/.../profile.zip
#           (the real URL includes a SAS token — download it on the client and
#            import into the OpenVPN/native client)
```

**Connecting the client is out of scope for this host** — importing the
package and dialing the tunnel is a Windows/macOS/OpenVPN-client task. The
exam-relevant work is everything above: the pool, the protocols, the trusted
root, and generating the package. Once a client connects, it leases a
`172.16.201.x` address and reaches the VNet exactly as an S2S peer's hosts do.

### Runbook: the other two auth models

- **Microsoft Entra ID** — OpenVPN only; no certificates. You authorize the
  *Azure VPN Client* enterprise app and set `--client-protocol OpenVPN` with
  the tenant/audience/issuer AAD parameters. Best for cloud-managed identity
  and Conditional Access.
- **RADIUS** — the gateway proxies auth to your RADIUS server (often NPS in
  front of AD), reaching it over the S2S tunnel. Bridges P2S to existing
  on-prem credentials.

## Step 6 — Clear the P2S profile (leave the gateway as Labs 1–3 expect)

Remove the profile so the gateway matches the S2S labs' goldens on any later
recapture. This does not delete the gateway — that is the module teardown.

<!-- @verify host=lab step=clear-p2s expect=/Succeeded/ rc=0 -->
```bash
RG=rg-straylight-az700-hybrid-vpn
# Removing vpnClientConfiguration clears the pool, protocols, AND the root
# certificates in one gateway update — the gateway returns to S2S-only.
az network vnet-gateway update --resource-group $RG --name vpngw-hub \
  --remove vpnClientConfiguration \
  --query provisioningState -o tsv
rm -f /tmp/p2s-work-dir
# Expected: Succeeded   (P2S profile cleared; the gateway is back to S2S-only)
```

## What you proved

- Point-to-site is a **profile on the existing VPN gateway**, not a new
  resource: a **client address pool** (Azure-side, non-overlapping), one or
  more **tunnel protocols**, and an **authentication model**.
- **OpenVPN + IKEv2 + SSTP** are the protocols; **OpenVPN** is the one that
  also carries **Entra ID** auth. Auth is **Azure certificate**, **Entra
  ID**, or **RADIUS**.
- Certificate auth trusts an uploaded **root**; clients import a
  gateway-**generated profile package** — there is no per-client server
  config and **no on-prem gateway** in the P2S model.
- P2S is a gateway *setting*: adding and clearing it is a `vnet-gateway
  update`, and it leaves no LNG or connection behind.
