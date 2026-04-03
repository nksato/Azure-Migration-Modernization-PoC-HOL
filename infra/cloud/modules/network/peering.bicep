// ============================================================
// VNet Peering (Hub ↔ 各 Spoke)
// ============================================================

param hubVnetName string
param hubVnetId string
param spoke1VnetId string
param spoke2VnetId string
param spoke3VnetId string
param spoke4VnetId string
param spoke1VnetName string
param spoke2VnetName string
param spoke3VnetName string
param spoke4VnetName string
param spoke1RgName string
param spoke2RgName string
param spoke3RgName string
param spoke4RgName string

// Hub → Spoke peerings
resource hubToSpoke1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${hubVnetName}/hub-to-spoke1'
  properties: {
    remoteVirtualNetwork: {
      id: spoke1VnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
  }
}

resource hubToSpoke2 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${hubVnetName}/hub-to-spoke2'
  properties: {
    remoteVirtualNetwork: {
      id: spoke2VnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
  }
}

resource hubToSpoke3 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${hubVnetName}/hub-to-spoke3'
  properties: {
    remoteVirtualNetwork: {
      id: spoke3VnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
  }
}

resource hubToSpoke4 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  name: '${hubVnetName}/hub-to-spoke4'
  properties: {
    remoteVirtualNetwork: {
      id: spoke4VnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
  }
}

// Spoke → Hub peerings
module spoke1ToHub 'peering-spoke-to-hub.bicep' = {
  name: 'peer-spoke1-to-hub'
  scope: resourceGroup(spoke1RgName)
  params: {
    spokeVnetName: spoke1VnetName
    hubVnetId: hubVnetId
  }
}

module spoke2ToHub 'peering-spoke-to-hub.bicep' = {
  name: 'peer-spoke2-to-hub'
  scope: resourceGroup(spoke2RgName)
  params: {
    spokeVnetName: spoke2VnetName
    hubVnetId: hubVnetId
  }
}

module spoke3ToHub 'peering-spoke-to-hub.bicep' = {
  name: 'peer-spoke3-to-hub'
  scope: resourceGroup(spoke3RgName)
  params: {
    spokeVnetName: spoke3VnetName
    hubVnetId: hubVnetId
  }
}

module spoke4ToHub 'peering-spoke-to-hub.bicep' = {
  name: 'peer-spoke4-to-hub'
  scope: resourceGroup(spoke4RgName)
  params: {
    spokeVnetName: spoke4VnetName
    hubVnetId: hubVnetId
  }
}
