// nat-gateway — topology for az700-vnet-4: a VNet + burstable VM with NO outbound
// path (no public IP, no NAT gateway — recent subnets have no default
// outbound access). The lab creates the NAT gateway + public IP and attaches
// them via CLI: explicit outbound connectivity is the exercise.
// Deploy/teardown via azure/scripts/az700.sh; ~2 min, < $0.30 per session.
import { tagsFor } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = tagsFor('nat-gateway', created)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-nat'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.104.0.0/24']
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: '10.104.0.0/24'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

module vm '../../modules/testvm.bicep' = {
  name: 'vm-nat1'
  params: {
    location: location
    tags: tags
    name: 'vm-nat1'
    subnetId: vnet.properties.subnets[0].id
  }
}

output vmName string = vm.outputs.vmName
output subnetId string = vnet.properties.subnets[0].id
