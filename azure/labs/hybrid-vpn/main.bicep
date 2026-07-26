// hybrid-vpn — topology for the az700-hybrid module: hub VNet + VPN gateway
// (20-45 min!) + local network gateway describing the Straylight lab as
// on-prem + the S2S connection + one test VM in snet-shared. The lab's vpn1
// (strongSwan) initiates the tunnel; Azure responds. onpremIp and sharedKey
// arrive dynamically via params.sh — never hardcoded, never committed.
// Deploy/teardown via azure/scripts/az700.sh; gateway ~$0.36/hr while up.
import { tagsFor } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')
param onpremIp string
@secure()
param sharedKey string
@allowed(['VpnGw1AZ', 'VpnGw2AZ'])
param skuName string = 'VpnGw1AZ'

var tags = tagsFor('hybrid-vpn', created)

module hub '../../modules/hub.bicep' = {
  name: 'hub'
  params: {
    location: location
    tags: tags
  }
}

module vpngw '../../modules/vpngw.bicep' = {
  name: 'vpngw'
  params: {
    location: location
    tags: tags
    // GatewaySubnet is subnet [0] in the hub module
    gatewaySubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', 'vnet-hub', 'GatewaySubnet')
    skuName: skuName
  }
  dependsOn: [hub]
}

module s2s '../../modules/lng-connection.bicep' = {
  name: 's2s'
  params: {
    location: location
    tags: tags
    gatewayId: vpngw.outputs.gatewayId
    onpremIp: onpremIp
    sharedKey: sharedKey
  }
}

module vm '../../modules/testvm.bicep' = {
  name: 'vm-hub1'
  params: {
    location: location
    tags: tags
    name: 'vm-hub1'
    subnetId: hub.outputs.sharedSubnetId
  }
}

output gatewayPublicIp string = vpngw.outputs.publicIpAddress
output connectionName string = s2s.outputs.connectionName
output vmName string = vm.outputs.vmName
