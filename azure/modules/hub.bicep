// Hub VNet: GatewaySubnet (/27, ready for a VPN gateway), snet-dns (DNS
// forwarder), snet-shared (general workloads). NSG on the workload subnets
// only — GatewaySubnet must not carry an NSG.
import { addressPlan } from 'naming.bicep'

param location string
param tags object = {}

resource nsgHub 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-hub'
  location: location
  tags: tags
  properties: {
    // Default rules only: AllowVnetInBound covers lab traffic (including the
    // on-prem range once it arrives via gateway), DenyAllInBound blocks the rest.
    securityRules: []
  }
}

resource hub 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-hub'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPlan.hub]
    }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: addressPlan.gatewaySubnet
        }
      }
      {
        name: 'snet-dns'
        properties: {
          addressPrefix: addressPlan.dnsSubnet
          networkSecurityGroup: { id: nsgHub.id }
        }
      }
      {
        name: 'snet-shared'
        properties: {
          addressPrefix: addressPlan.sharedSubnet
          networkSecurityGroup: { id: nsgHub.id }
        }
      }
    ]
  }
}

output vnetId string = hub.id
output vnetName string = hub.name
output sharedSubnetId string = hub.properties.subnets[2].id
output dnsSubnetId string = hub.properties.subnets[1].id
