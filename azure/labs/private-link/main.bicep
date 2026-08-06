// private-link — topology for az700-private-1 (service endpoints) and
// az700-private-2 (private endpoint to storage). One VNet with a workload
// subnet (the VM + the service-endpoint subject) and a dedicated
// private-endpoint subnet, plus a storage account the labs restrict (Lab 1
// service endpoint + firewall) and then make fully private (Lab 2 private
// endpoint + private DNS). Both labs create their own private resources as
// steps, so they die with the RG. Deploy/teardown via azure/scripts/az700.sh.
import { tagsFor, addressPlan } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = tagsFor('private-link', created)
var vnetName = 'vnet-plink'
// Globally-unique, deterministic-per-RG storage name (lowercase alphanumeric).
var storageName = 'st${uniqueString(resourceGroup().id)}'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPlan.privateLink.vnet]
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: addressPlan.privateLink.workload
        }
      }
      {
        // Private endpoints need network policies disabled on their subnet.
        name: 'snet-pe'
        properties: {
          addressPrefix: addressPlan.privateLink.endpoint
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    // Starts open (Lab 1 tightens the firewall; Lab 2 adds a private endpoint).
    publicNetworkAccess: 'Enabled'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

module vm '../../modules/testvm.bicep' = {
  name: 'vm-plink1'
  params: {
    location: location
    tags: tags
    name: 'vm-plink1'
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-workload')
  }
  dependsOn: [vnet]
}

output storageAccountName string = storage.name
output vnetName string = vnet.name
output vmName string = vm.outputs.vmName
