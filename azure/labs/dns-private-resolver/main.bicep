// dns-private-resolver — standalone topology for az700-dns-3. A DNS Private
// Resolver is a DEPLOYED resource (unlike the dns module's zones, which are
// lab steps), so it gets its own topology. Kept standalone (its own small
// VNet, no gateway) — the resolver mechanics (inbound/outbound endpoints,
// forwarding ruleset, VNet link) are fully demonstrable in isolation and
// cheaply. The cross-tunnel hybrid-resolution story needs hybrid-vpn standing
// and is a runbook extension in the lab, not deployed here.
// Deploy/teardown via azure/scripts/az700.sh; ~2 endpoints × ~$0.07/hr + 1 VM.
import { tagsFor, addressPlan } from '../../modules/naming.bicep'

param location string = resourceGroup().location
param created string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

var tags = tagsFor('dns-private-resolver', created)
var vnetName = 'vnet-dnsr'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPlan.dnsResolver.vnet]
    }
    subnets: [
      {
        // Inbound and outbound endpoints each need their OWN subnet, /28 min,
        // delegated to Microsoft.Network/dnsResolvers, and otherwise empty.
        name: 'snet-inbound'
        properties: {
          addressPrefix: addressPlan.dnsResolver.inbound
          delegations: [
            {
              name: 'dnsr'
              properties: { serviceName: 'Microsoft.Network/dnsResolvers' }
            }
          ]
        }
      }
      {
        name: 'snet-outbound'
        properties: {
          addressPrefix: addressPlan.dnsResolver.outbound
          delegations: [
            {
              name: 'dnsr'
              properties: { serviceName: 'Microsoft.Network/dnsResolvers' }
            }
          ]
        }
      }
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: addressPlan.dnsResolver.workload
        }
      }
    ]
  }
}

resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: 'dnsr-straylight'
  location: location
  tags: tags
  properties: {
    virtualNetwork: { id: vnet.id }
  }
}

resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: 'inbound'
  location: location
  properties: {
    ipConfigurations: [
      {
        // The private IP on-prem forwards to (allocated in snet-inbound).
        privateIpAllocationMethod: 'Dynamic'
        subnet: {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-inbound')
        }
      }
    ]
  }
}

resource outbound 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' = {
  parent: resolver
  name: 'outbound'
  location: location
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-outbound')
    }
  }
}

resource ruleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: 'fwrs-straylight'
  location: location
  tags: tags
  properties: {
    dnsResolverOutboundEndpoints: [
      { id: outbound.id }
    ]
  }
}

resource rule 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = {
  parent: ruleset
  name: 'straylight-lab'
  properties: {
    // Azure queries for the on-prem zone go out the outbound endpoint to the
    // on-prem DNS. The target is reachable only over the S2S tunnel — this
    // rule is asserted for shape; the live answer is the runbook extension.
    domainName: 'straylight.lab.'
    targetDnsServers: [
      { ipAddress: '192.168.56.10', port: 53 }
    ]
    forwardingRuleState: 'Enabled'
  }
}

resource link 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = {
  parent: ruleset
  name: 'vnet-dnsr-link'
  properties: {
    virtualNetwork: { id: vnet.id }
  }
}

// Test VM for resolution probes from inside the VNet.
module vm '../../modules/testvm.bicep' = {
  name: 'vm-dnsr1'
  params: {
    location: location
    tags: tags
    name: 'vm-dnsr1'
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-workload')
  }
  dependsOn: [vnet]
}

output resolverName string = resolver.name
output inboundEndpointName string = inbound.name
output rulesetName string = ruleset.name
