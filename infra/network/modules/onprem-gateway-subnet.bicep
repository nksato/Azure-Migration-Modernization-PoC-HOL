// ============================================================
// onprem-gateway-subnet.bicep
// 疑似オンプレ VNet に GatewaySubnet を追加
// ============================================================

param vnetName string
param gatewaySubnetPrefix string = '10.0.255.0/27'

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
