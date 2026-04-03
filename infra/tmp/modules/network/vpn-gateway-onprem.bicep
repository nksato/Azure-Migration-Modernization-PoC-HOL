// ============================================================
// VPN Gateway (OnPrem 側) — vpn-gateway.bicep から呼び出し
// ============================================================

param location string
param tags object
param onpremVnetName string

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-vgw-onprem'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource gw 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = {
  name: 'vgw-onprem'
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', onpremVnetName, 'GatewaySubnet')
          }
        }
      }
    ]
  }
}

output gatewayId string = gw.id
