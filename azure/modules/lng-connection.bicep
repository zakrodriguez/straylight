// The on-prem site as Azure sees it: a local network gateway (the lab's
// public IP + its 192.168.56.0/21 host-only supernet) and the IPsec
// connection to the hub's VPN gateway. Azure is the RESPONDER: the lab's
// strongSwan VM (vpn1) initiates, so no port-forwards are needed at home.
// BGP starts OFF — enabling it (LNG bgpSettings + connection flag) is a lab
// exercise, not deploy state.
import { addressPlan } from 'naming.bicep'

param location string
param tags object = {}
param gatewayId string
param onpremIp string
@secure()
param sharedKey string

var onpremAddressSpace = addressPlan.onprem

resource lng 'Microsoft.Network/localNetworkGateways@2024-05-01' = {
  name: 'lgw-straylight'
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: onpremIp
    localNetworkAddressSpace: {
      addressPrefixes: [onpremAddressSpace]
    }
  }
}

resource conn 'Microsoft.Network/connections@2024-05-01' = {
  name: 'cn-straylight-s2s'
  location: location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
    virtualNetworkGateway1: { id: gatewayId, properties: {} }
    localNetworkGateway2: { id: lng.id, properties: {} }
    sharedKey: sharedKey
    enableBgp: false
    // Explicit IPsec/IKE policy. Azure's *default* policy set did not
    // negotiate against strongSwan on VpnGw1AZ — the initiator got
    // NO_PROPOSAL_CHOSEN at IKE_SA_INIT for every combination in Azure's
    // documented default list (live-verified 2026-07-27). Pinning one
    // policy makes negotiation deterministic; strongswan_azure's
    // proposals (aes256-sha256-modp2048 / aes256-sha256, no PFS) match
    // this exactly.
    usePolicyBasedTrafficSelectors: false
    ipsecPolicies: [
      {
        saLifeTimeSeconds: 27000
        saDataSizeKilobytes: 102400000
        ipsecEncryption: 'AES256'
        ipsecIntegrity: 'SHA256'
        ikeEncryption: 'AES256'
        ikeIntegrity: 'SHA256'
        dhGroup: 'DHGroup14'
        pfsGroup: 'None'
      }
    ]
  }
}

output connectionName string = conn.name
output lngName string = lng.name
