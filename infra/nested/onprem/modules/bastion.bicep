// ============================================================================
// Bastion Module - Azure Bastion (Standard SKU)
// - Tunneling enabled for native client support
// - File copy enabled for file transfer via Bastion
// ============================================================================

param location string
param bastionName string
param bastionSubnetId string

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${bastionName}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableFileCopy: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          publicIPAddress: {
            id: bastionPip.id
          }
          subnet: {
            id: bastionSubnetId
          }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
output bastionName string = bastion.name
