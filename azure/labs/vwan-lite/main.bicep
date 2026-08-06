// vwan-lite — runbook topology for az700-hybrid-5 (Virtual WAN). A Standard
// virtual WAN + one Microsoft-managed virtual hub (~30 min to provision,
// ~$0.25/hr routing infra) + one spoke VNet connected to the hub to show
// automatic any-to-any transit. NOT part of the verified set (no golden);
// deploy only for hands-on reps, and DESTROY THE SAME DAY.
import { tagsFor, addressPlan } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = tagsFor('vwan-lite', created)

resource vwan 'Microsoft.Network/virtualWans@2024-05-01' = {
  name: 'vwan-straylight'
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    allowVnetToVnetTraffic: true
    allowBranchToBranchTraffic: true
  }
}

resource hub 'Microsoft.Network/virtualHubs@2024-05-01' = {
  name: 'vhub1'
  location: location
  tags: tags
  properties: {
    // A virtual hub is Microsoft-managed; you give it a dedicated /23 and
    // never subnet it yourself.
    addressPrefix: addressPlan.vwan.hub
    virtualWan: { id: vwan.id }
    sku: 'Standard'
  }
}

resource spoke 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-vwan-spoke1'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPlan.vwan.spoke1]
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: { addressPrefix: cidrSubnet(addressPlan.vwan.spoke1, 27, 0) }
      }
    ]
  }
}

// The hub VNet connection: binds the spoke to the managed hub. Its prefix
// then appears in the hub's defaultRouteTable automatically — no UDR.
resource conn 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2024-05-01' = {
  parent: hub
  name: 'cn-vwan-spoke1'
  properties: {
    remoteVirtualNetwork: { id: spoke.id }
  }
}

output vwanName string = vwan.name
output hubName string = hub.name
output connectionName string = conn.name
