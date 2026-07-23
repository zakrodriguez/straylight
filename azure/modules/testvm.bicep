// Minimal test VM: burstable Ubuntu (Bsv2 default), NO public IP. Access is
// `az vm run-command invoke` only — the generated GUID password is never used
// interactively and is not recorded anywhere.
param location string
param tags object = {}
param name string
param subnetId string
// Bsv2 first: gen-1 B-series (B1s/B2s) is capacity-restricted region-wide on
// some subscriptions (SkuNotAvailable at preflight, hit live in centralus AND
// eastus2); the v2 sizes were unrestricted and B2ts_v2 is cheaper than B1s.
@allowed(['Standard_B2ts_v2', 'Standard_B2ats_v2', 'Standard_B2als_v2', 'Standard_B1s', 'Standard_B2s'])
param vmSize string = 'Standard_B2ts_v2'
param adminUsername string = 'azureuser'
@secure()
param adminPassword string = newGuid()

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

output vmName string = vm.name
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
