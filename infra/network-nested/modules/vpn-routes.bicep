// ============================================================================
// VPN Routes for On-prem
// - Adds GatewaySubnet to existing VNet for VPN Gateway deployment
// ============================================================================

param vnetName string
param gatewaySubnetPrefix string = '10.1.255.0/27'

// --- Add GatewaySubnet to on-prem VNet ---
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: gatewaySubnetPrefix
  }
}
