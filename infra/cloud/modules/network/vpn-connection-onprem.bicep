// ============================================================
// VPN Connection OnPrem → Hub — vpn-gateway.bicep から呼び出し
// ============================================================

param location string
param tags object
param onpremGatewayId string
param hubGatewayId string

@secure()
param sharedKey string

resource connection 'Microsoft.Network/connections@2024-01-01' = {
  name: 'cn-onprem-to-hub'
  location: location
  tags: tags
  properties: {
    connectionType: 'Vnet2Vnet'
    virtualNetworkGateway1: {
      id: onpremGatewayId
      properties: {}
    }
    virtualNetworkGateway2: {
      id: hubGatewayId
      properties: {}
    }
    sharedKey: sharedKey
  }
}
