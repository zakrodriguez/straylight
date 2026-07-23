// Spoke VNet with one workload subnet spanning the whole space. Peering to the
// hub is optional: hub-spoke lab topologies leave peerToHub=false because
// creating the peering IS the exercise; hybrid topologies set it true with
// useHubGateway for gateway transit.
param location string
param tags object = {}
param name string
param addressPrefix string
param hubVnetName string
param peerToHub bool = false
param useHubGateway bool = false

resource hub 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
}

resource spoke 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: addressPrefix
        }
      }
    ]
  }
}

resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = if (peerToHub) {
  parent: hub
  name: 'hub-to-${name}'
  properties: {
    remoteVirtualNetwork: { id: spoke.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: useHubGateway
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = if (peerToHub) {
  parent: spoke
  name: '${name}-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hub.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: useHubGateway
  }
}

output vnetId string = spoke.id
output vnetName string = spoke.name
output workloadSubnetId string = spoke.properties.subnets[0].id
