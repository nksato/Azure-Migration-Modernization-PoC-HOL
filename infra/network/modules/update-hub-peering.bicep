// ============================================================
// update-hub-peering.bicep
// VPN Gateway デプロイ後に Hub-Spoke Peering を更新して
// Gateway Transit を有効化する
// ============================================================

param location string
param hubVnetResourceId string
param spoke1VnetId string
param spoke2VnetId string
param spoke3VnetId string
param spoke4VnetId string

// Hub VNet を再デプロイして peering の allowGatewayTransit を有効化
module hubPeering 'br/public:avm/res/network/virtual-network:0.7.2' = {
  params: {
    name: 'vnet-hub'
    location: location
    addressPrefixes: ['10.10.0.0/16']
    peerings: [
      {
        remoteVirtualNetworkResourceId: spoke1VnetId
        allowForwardedTraffic: true
        allowGatewayTransit: true
        useRemoteGateways: false
      }
      {
        remoteVirtualNetworkResourceId: spoke2VnetId
        allowForwardedTraffic: true
        allowGatewayTransit: true
        useRemoteGateways: false
      }
      {
        remoteVirtualNetworkResourceId: spoke3VnetId
        allowForwardedTraffic: true
        allowGatewayTransit: true
        useRemoteGateways: false
      }
      {
        remoteVirtualNetworkResourceId: spoke4VnetId
        allowForwardedTraffic: true
        allowGatewayTransit: true
        useRemoteGateways: false
      }
    ]
  }
}

// Spoke VNet の peering も useRemoteGateways: true に更新
module spoke1PeeringUpdate 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: resourceGroup(split(spoke1VnetId, '/')[4])
  params: {
    name: 'vnet-spoke1'
    location: location
    addressPrefixes: ['10.20.0.0/16']
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: true
      }
    ]
  }
}

module spoke2PeeringUpdate 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: resourceGroup(split(spoke2VnetId, '/')[4])
  params: {
    name: 'vnet-spoke2'
    location: location
    addressPrefixes: ['10.21.0.0/16']
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: true
      }
    ]
  }
}

module spoke3PeeringUpdate 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: resourceGroup(split(spoke3VnetId, '/')[4])
  params: {
    name: 'vnet-spoke3'
    location: location
    addressPrefixes: ['10.22.0.0/16']
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: true
      }
    ]
  }
}

module spoke4PeeringUpdate 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: resourceGroup(split(spoke4VnetId, '/')[4])
  params: {
    name: 'vnet-spoke4'
    location: location
    addressPrefixes: ['10.23.0.0/16']
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: true
      }
    ]
  }
}
