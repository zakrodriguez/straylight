// hub-spoke — base topology for the az700-vnet module: hub VNet + two spokes
// (deliberately UNPEERED: creating the peerings is the lab exercise) + one burstable
// test VM in spoke1 for effective-route inspection.
// Deploy/teardown via azure/scripts/az700.sh; ~2 min, < $0.25 per session.
import { tagsFor, addressPlan } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = tagsFor('hub-spoke', created)

module hub '../../modules/hub.bicep' = {
  name: 'hub'
  params: {
    location: location
    tags: tags
  }
}

module spoke1 '../../modules/spoke.bicep' = {
  name: 'spoke1'
  params: {
    location: location
    tags: tags
    name: 'vnet-spoke1'
    addressPrefix: addressPlan.spoke1
    hubVnetName: hub.outputs.vnetName
    peerToHub: false
  }
}

module spoke2 '../../modules/spoke.bicep' = {
  name: 'spoke2'
  params: {
    location: location
    tags: tags
    name: 'vnet-spoke2'
    addressPrefix: addressPlan.spoke2
    hubVnetName: hub.outputs.vnetName
    peerToHub: false
  }
}

module vmSpoke1 '../../modules/testvm.bicep' = {
  name: 'vm-spoke1'
  params: {
    location: location
    tags: tags
    name: 'vm-spoke1'
    subnetId: spoke1.outputs.workloadSubnetId
  }
}

output hubVnetId string = hub.outputs.vnetId
output vmPrivateIp string = vmSpoke1.outputs.privateIp
