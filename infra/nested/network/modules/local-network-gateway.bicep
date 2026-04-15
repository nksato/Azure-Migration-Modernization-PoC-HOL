// ============================================================================
// Local Network Gateway
// Represents the remote side of an S2S VPN connection
// ============================================================================

param location string
param name string
param gatewayIpAddress string
param addressPrefixes string[]
param tags object = {}

resource lgw 'Microsoft.Network/localNetworkGateways@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: gatewayIpAddress
    localNetworkAddressSpace: {
      addressPrefixes: addressPrefixes
    }
  }
}

output resourceId string = lgw.id
output name string = lgw.name
