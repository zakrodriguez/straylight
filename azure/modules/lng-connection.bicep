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
  }
}

output connectionName string = conn.name
output lngName string = lng.name
