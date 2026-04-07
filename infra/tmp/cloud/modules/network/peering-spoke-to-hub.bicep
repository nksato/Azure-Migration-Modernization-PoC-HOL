// ============================================================
// Spoke → Hub Peering（peering.bicep から呼び出し）
// ============================================================

param spokeVnetName string
param hubVnetId string

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${spokeVnetName}/${spokeVnetName}-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
  }
}
