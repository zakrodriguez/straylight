// VPN gateway for the hybrid module: route-based, IKEv2, BGP-capable
// (ASN 65515 default). AZ SKUs only — the sku floor is the cost guardrail.
// Provisioning takes 20-45 minutes: the gateway is ALWAYS deployed by the
// topology (Part A of the lab), never created inside lab steps; labs gate on
// `az700.sh watch hybrid-vpn` instead.
param location string
param tags object = {}
param gatewaySubnetId string
@allowed(['VpnGw1AZ', 'VpnGw2AZ'])
param skuName string = 'VpnGw1AZ'

// AZ gateway SKUs require a zone-redundant Standard static public IP.
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-vpngw'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpngw 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: 'vpngw-hub'
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    sku: { name: skuName, tier: skuName }
    activeActive: false
    enableBgp: true
    bgpSettings: { asn: 65515 }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          subnet: { id: gatewaySubnetId }
          publicIPAddress: { id: pip.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

output gatewayId string = vpngw.id
output gatewayName string = vpngw.name
output publicIpAddress string = pip.properties.ipAddress
