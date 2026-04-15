// ============================================================================
// Main - Pseudo on-premises environment with Nested Hyper-V
//
// Architecture:
//   VNet (closed network)
//   ├── AzureBastionSubnet  → Azure Bastion (Standard)
//   └── snet-onprem-nested  → Hyper-V Host VM (no internet, UDR block)
// ============================================================================

targetScope = 'resourceGroup'

@description('Deployment region')
param location string = resourceGroup().location

@description('Resource name prefix')
param prefix string = 'onprem'

@description('VM administrator username')
param adminUsername string

@secure()
@description('VM administrator password')
param adminPassword string

@description('VM size (must support nested virtualization)')
param vmSize string = 'Standard_E8s_v5'

@description('Data disk size in GB for Hyper-V VM storage')
param dataDiskSizeGB int = 256

// ----------------------------------------------------------------------------
// Network - Closed VNet with Bastion and on-prem subnets
// ----------------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    vnetName: 'vnet-${prefix}'
  }
}

// ----------------------------------------------------------------------------
// Bastion - Secure management access
// ----------------------------------------------------------------------------
module bastion 'modules/bastion.bicep' = {
  name: 'deploy-bastion'
  params: {
    location: location
    bastionName: 'bas-${prefix}'
    bastionSubnetId: network.outputs.bastionSubnetId
  }
}

// ----------------------------------------------------------------------------
// Hyper-V Host - Nested virtualization VM
// ----------------------------------------------------------------------------
module hypervHost 'modules/hyperv-host.bicep' = {
  name: 'deploy-hyperv-host'
  params: {
    location: location
    vmName: 'vm-${prefix}-hv01'
    subnetId: network.outputs.onpremSubnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    dataDiskSizeGB: dataDiskSizeGB
  }
}

// ----------------------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------------------
output vnetName string = network.outputs.vnetName
output bastionName string = bastion.outputs.bastionName
output hypervHostName string = hypervHost.outputs.vmName
output hypervHostPrivateIp string = hypervHost.outputs.privateIpAddress
