// ============================================================
// VPN Gateway (Hub 側 + OnPrem 側) + VNet-to-VNet 接続
// ============================================================

param location string
param tags object
param hubVnetName string
param onpremVnetName string
param onpremRgName string

@secure()
param sharedKey string = newGuid()

// Hub 側 Gateway
resource pipHubGw 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-vgw-hub'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource hubGw 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = {
  name: 'vgw-hub'
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          publicIPAddress: {
            id: pipHubGw.id
          }
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName, 'GatewaySubnet')
          }
        }
      }
    ]
  }
}

// OnPrem 側 Gateway
module onpremGw 'vpn-gateway-onprem.bicep' = {
  name: 'deploy-vpn-gw-onprem'
  scope: resourceGroup(onpremRgName)
  params: {
    location: location
    tags: tags
    onpremVnetName: onpremVnetName
  }
}

// Hub → OnPrem 接続
resource hubToOnpremConnection 'Microsoft.Network/connections@2024-01-01' = {
  name: 'cn-hub-to-onprem'
  location: location
  tags: tags
  properties: {
    connectionType: 'Vnet2Vnet'
    virtualNetworkGateway1: {
      id: hubGw.id
      properties: {}
    }
    virtualNetworkGateway2: {
      id: onpremGw.outputs.gatewayId
      properties: {}
    }
    sharedKey: sharedKey
  }
}

// OnPrem → Hub 接続
module onpremToHubConnection 'vpn-connection-onprem.bicep' = {
  name: 'deploy-vpn-cn-onprem-to-hub'
  scope: resourceGroup(onpremRgName)
  params: {
    location: location
    tags: tags
    onpremGatewayId: onpremGw.outputs.gatewayId
    hubGatewayId: hubGw.id
    sharedKey: sharedKey
  }
}
