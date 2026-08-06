// appgw — topology for az700-lb-2 (Application Gateway URL-path routing) and
// referenced by az700-lb-3 (WAF, runbook). A Standard_v2 gateway (capacity 1,
// the cost floor) with a URL-path map: /images/* -> pool-images (vm-appgw2),
// everything else -> pool-default (vm-appgw1). Each backend serves its hostname
// on :80, so curling the gateway with and without the path proves the routing.
// App Gateway takes ~15-20 min to provision — it is ALWAYS deployed by the
// topology (Part A of the lab), never inside a lab step.
// Deploy/teardown via azure/scripts/az700.sh; AppGW ~$0.25/hr while up.
import { tagsFor, addressPlan } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = tagsFor('appgw', created)
var agwName = 'agw-straylight'
var vnetName = 'vnet-appgw'
var agwId = resourceId('Microsoft.Network/applicationGateways', agwName)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPlan.appgw.vnet]
    }
    subnets: [
      {
        // App Gateway requires its OWN dedicated subnet (no other resources).
        name: 'snet-appgw'
        properties: {
          addressPrefix: addressPlan.appgw.gateway
        }
      }
      {
        name: 'snet-backend'
        properties: {
          addressPrefix: addressPlan.appgw.backend
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'agwpip-straylight'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource agw 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: agwName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'gwip'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-appgw')
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: {
          publicIPAddress: { id: pip.id }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port80'
        properties: { port: 80 }
      }
    ]
    backendAddressPools: [
      { name: 'pool-default' }
      { name: 'pool-images' }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'http-settings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 20
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-http'
        properties: {
          frontendIPConfiguration: {
            id: '${agwId}/frontendIPConfigurations/frontend'
          }
          frontendPort: {
            id: '${agwId}/frontendPorts/port80'
          }
          protocol: 'Http'
        }
      }
    ]
    urlPathMaps: [
      {
        name: 'pathmap'
        properties: {
          defaultBackendAddressPool: {
            id: '${agwId}/backendAddressPools/pool-default'
          }
          defaultBackendHttpSettings: {
            id: '${agwId}/backendHttpSettingsCollection/http-settings'
          }
          pathRules: [
            {
              name: 'images'
              properties: {
                paths: ['/images/*']
                backendAddressPool: {
                  id: '${agwId}/backendAddressPools/pool-images'
                }
                backendHttpSettings: {
                  id: '${agwId}/backendHttpSettingsCollection/http-settings'
                }
              }
            }
          ]
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule-pathbased'
        properties: {
          ruleType: 'PathBasedRouting'
          priority: 100
          httpListener: {
            id: '${agwId}/httpListeners/listener-http'
          }
          urlPathMap: {
            id: '${agwId}/urlPathMaps/pathmap'
          }
        }
      }
    ]
  }
}

module vm1 '../../modules/backendvm.bicep' = {
  name: 'vm-appgw1'
  params: {
    location: location
    tags: tags
    name: 'vm-appgw1'
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-backend')
    appgwBackendPoolIds: ['${agwId}/backendAddressPools/pool-default']
  }
  dependsOn: [vnet, agw]
}

module vm2 '../../modules/backendvm.bicep' = {
  name: 'vm-appgw2'
  params: {
    location: location
    tags: tags
    name: 'vm-appgw2'
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-backend')
    appgwBackendPoolIds: ['${agwId}/backendAddressPools/pool-images']
  }
  dependsOn: [vnet, agw]
}

output gatewayName string = agw.name
output frontendPublicIp string = pip.properties.ipAddress
output backendVmNames array = [vm1.outputs.vmName, vm2.outputs.vmName]
