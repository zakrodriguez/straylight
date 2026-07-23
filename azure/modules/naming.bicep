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
}
