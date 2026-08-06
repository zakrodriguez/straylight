// lb-standard — topology for az700-lb-1 (Standard Load Balancer) and reused by
// az700-lb-4 (Traffic Manager). A public Standard LB fronting two backend VMs
// that each serve their hostname on :80 (cloud-init, no internet needed), so
// the LB genuinely distributes and `curl` on the frontend proves it. The NSG
// admits HTTP from the internet (frontend flow) and from AzureLoadBalancer
// (health probes) — Standard LB is closed by default.
// Deploy/teardown via azure/scripts/az700.sh; ~2 VMs + LB + 1 pip, < $0.30/session.
import { tagsFor, addressPlan } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = tagsFor('lb-standard', created)
var lbName = 'lb-straylight'
var poolName = 'bepool'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-lb-backend'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP-Internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-LB-Probe'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-lb'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPlan.lbStandard.vnet]
    }
    subnets: [
      {
        name: 'snet-backend'
        properties: {
          addressPrefix: addressPlan.lbStandard.backend
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'lbpip-straylight'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: lbName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: {
          publicIPAddress: { id: pip.id }
        }
      }
    ]
    backendAddressPools: [
      { name: poolName }
    ]
    probes: [
      {
        name: 'probe-http'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-http'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, poolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'probe-http')
          }
          idleTimeoutInMinutes: 4
          enableFloatingIP: false
          // The dedicated outbound rule (below) owns SNAT for this frontend, so
          // the LB rule must disable its own inline outbound SNAT — Azure
          // rejects the deployment otherwise.
          disableOutboundSnat: true
        }
      }
    ]
    outboundRules: [
      {
        name: 'outbound'
        properties: {
          protocol: 'All'
          allocatedOutboundPorts: 0
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'frontend')
            }
          ]
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, poolName)
          }
        }
      }
    ]
  }
}

module vm1 '../../modules/backendvm.bicep' = {
  name: 'vm-lb1'
  params: {
    location: location
    tags: tags
    name: 'vm-lb1'
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', 'vnet-lb', 'snet-backend')
    lbBackendPoolIds: [resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, poolName)]
  }
  dependsOn: [vnet, lb]
}

module vm2 '../../modules/backendvm.bicep' = {
  name: 'vm-lb2'
  params: {
    location: location
    tags: tags
    name: 'vm-lb2'
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', 'vnet-lb', 'snet-backend')
    lbBackendPoolIds: [resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, poolName)]
  }
  dependsOn: [vnet, lb]
}

output loadBalancerName string = lb.name
output frontendPublicIp string = pip.properties.ipAddress
output backendVmNames array = [vm1.outputs.vmName, vm2.outputs.vmName]
