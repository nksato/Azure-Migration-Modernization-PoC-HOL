// ============================================================================
// VPN Gateway Module
// - Public IP (Standard SKU, Static)
// - VPN Gateway (RouteBased) in existing GatewaySubnet
// ============================================================================

param location string
param gatewayName string
param publicIpName string
param vnetName string
param sku string = 'VpnGw1AZ'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'GatewaySubnet'
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: gatewayName
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: sku
      tier: sku
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: gatewaySubnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

output gatewayId string = vpnGateway.id
output gatewayName string = vpnGateway.name
