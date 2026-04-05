// ============================================================
// vpn-connection-hub.bicep
// Hub 側に Local Network Gateway と S2S VPN 接続を作成
// (オンプレ方向への逆接続)
// ============================================================

param location string
param tags object

@secure()
param vpnSharedKey string

param hubVpnGatewayId string
param remoteGatewayIp string
param remoteAddressPrefix string

// Local Network Gateway (オンプレ側を表す)
resource localNetworkGateway 'Microsoft.Network/localNetworkGateways@2024-05-01' = {
  name: 'lgw-onprem'
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: remoteGatewayIp
    localNetworkAddressSpace: {
      addressPrefixes: [
        remoteAddressPrefix
      ]
    }
  }
}

// S2S VPN 接続
resource vpnConnection 'Microsoft.Network/connections@2024-05-01' = {
  name: 'cn-hub-to-onprem'
  location: location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: hubVpnGatewayId
      properties: {}
    }
    localNetworkGateway2: {
      id: localNetworkGateway.id
      properties: {}
    }
    sharedKey: vpnSharedKey
    connectionProtocol: 'IKEv2'
  }
}
