// ============================================================
// vpn-connection.bicep
// オンプレ側に Local Network Gateway と S2S VPN 接続を作成
// ============================================================

param location string
param tags object

@secure()
param vpnSharedKey string

param onpremVpnGatewayId string
param remoteGatewayIp string
param remoteAddressPrefix string

// Local Network Gateway (Hub 側を表す)
resource localNetworkGateway 'Microsoft.Network/localNetworkGateways@2024-05-01' = {
  name: 'lgw-hub'
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
  name: 'cn-onprem-to-hub'
  location: location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: onpremVpnGatewayId
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
