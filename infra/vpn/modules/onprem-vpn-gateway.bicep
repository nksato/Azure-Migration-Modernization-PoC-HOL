// ============================================================
// onprem-vpn-gateway.bicep
// 疑似オンプレ VNet に GatewaySubnet を追加し、VPN Gateway をデプロイ
// ============================================================

param location string
param tags object
param vnetName string

// 既存 VNet の参照
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

// GatewaySubnet を追加 (既に存在する場合は既存を使用)
resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: '10.0.255.0/27'
  }
}

// VPN Gateway 用 Public IP
resource vpnGatewayPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'vgw-onprem-pip1'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// VPN Gateway
resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: 'vgw-onprem'
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1AZ'
      tier: 'VpnGw1AZ'
    }
    ipConfigurations: [
      {
        name: 'vpnGwIpConfig'
        properties: {
          publicIPAddress: {
            id: vpnGatewayPip.id
          }
          subnet: {
            id: gatewaySubnet.id
          }
        }
      }
    ]
  }
}

output vpnGatewayId string = vpnGateway.id
output vpnGatewayPublicIp string = vpnGatewayPip.properties.ipAddress
