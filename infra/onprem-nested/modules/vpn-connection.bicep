// ============================================================================
// VPN Connection Module - VNet-to-VNet
// ============================================================================

param location string
param connectionName string
param localGatewayId string
param remoteGatewayId string

@secure()
param sharedKey string

resource connection 'Microsoft.Network/connections@2024-05-01' = {
  name: connectionName
  location: location
  properties: {
    connectionType: 'Vnet2Vnet'
    sharedKey: sharedKey
    virtualNetworkGateway1: {
      id: localGatewayId
      properties: {}
    }
    virtualNetworkGateway2: {
      id: remoteGatewayId
      properties: {}
    }
  }
}

output connectionId string = connection.id
