// ============================================================
// GatewaySubnet に Route Table を関連付ける
// ============================================================
// Hub VNet → Firewall → Route Table の順でデプロイされるため、
// GatewaySubnet への関連付けは後から行う必要がある。

param routeTableId string

resource vnetHub 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: 'vnet-hub'
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnetHub
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: '10.10.255.0/27'
    routeTable: {
      id: routeTableId
    }
  }
}
