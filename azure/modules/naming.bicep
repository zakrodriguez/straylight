// Shared constants for the AZ-700 track. Consumed via compile-time imports:
//   import { tagsFor, addressPlan } from '../../modules/naming.bicep'
//
// The address plan is the single source of truth shared with
// docs/walkthroughs/STRAYLIGHT-REFERENCE.md ("Azure conventions"): everything
// Azure-side draws from 10.100.0.0/14 so the on-prem selectors and lab-VM
// static routes never change per lab. 10.0.2.0/24 (VirtualBox NAT) and
// 172.17.0.0/16 (Docker default bridge) must never appear on the Azure side.

@export()
func tagsFor(slug string, created string) object => {
  project: 'straylight'
  track: 'az700'
  lab: slug
  created: created
}

@export()
var addressPlan = {
  hub: '10.100.0.0/22'
  gatewaySubnet: '10.100.0.0/27'
  dnsSubnet: '10.100.1.0/24'
  sharedSubnet: '10.100.2.0/24'
  spoke1: '10.101.0.0/24'
  spoke2: '10.102.0.0/24'
  p2sPool: '172.16.201.0/24'
  onprem: '192.168.56.0/21'
  // DNS Private Resolver (dns-3): standalone VNet, inbound/outbound endpoints
  // on their own /28 subnets delegated to Microsoft.Network/dnsResolvers.
  dnsResolver: {
    vnet: '10.103.4.0/24'
    inbound: '10.103.4.0/28'
    outbound: '10.103.4.16/28'
    workload: '10.103.4.32/27'
  }
  // Virtual WAN (hybrid-5, runbook): Microsoft-managed hub wants a dedicated
  // /23; one spoke VNet connects to it.
  vwan: {
    hub: '10.103.8.0/23'
    spoke1: '10.103.10.0/24'
  }
  // Standard Load Balancer (lb-1, reused by traffic-manager lb-4): one VNet,
  // one backend subnet holding the LB's two backend VMs.
  lbStandard: {
    vnet: '10.103.12.0/24'
    backend: '10.103.12.0/27'
  }
  // Application Gateway (lb-2, referenced by waf lb-3): the gateway needs its
  // OWN dedicated subnet (no other resources), separate from the backends.
  appgw: {
    vnet: '10.103.13.0/24'
    gateway: '10.103.13.0/26'
    backend: '10.103.13.64/27'
  }
}
