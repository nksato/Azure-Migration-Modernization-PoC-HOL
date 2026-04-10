// ============================================================================
// VPN Deploy - On-premises (rg-onprem-nested) <-> Hub (rg-hub)
//
// Architecture:
//   rg-onprem-nested             rg-hub
//   ┌──────────────────┐         ┌──────────────────┐
//   │ vnet-onprem       │         │ vnet-hub          │
//   │ 10.1.0.0/16       │         │ 10.10.0.0/16      │
//   │                   │         │                   │
//   │ ┌───────────────┐ │   VPN   │ ┌───────────────┐ │
//   │ │ GatewaySubnet │◄├─────────┤►│ GatewaySubnet │ │
//   │ │ 10.1.255.0/27 │ │  IPsec  │ │10.10.255.0/27 │ │
//   │ └───────────────┘ │         │ └───────────────┘ │
//   └──────────────────┘         └──────────────────┘
//
// Prerequisites:
//   1. On-premises environment deployed (main.bicep)
//   2. Cloud environment deployed (Azure-Migration-Modernization-PoC-HOL)
//
// Usage patterns:
//   A) Standalone (onprem-nested only → Hub):
//      createHubVpnGateway = true  → Hub VPN GW を新規作成
//      デプロイ後、別途 Hub-Spoke ピアリングの Gateway Transit 有効化が必要
//
//   B) Dual (onprem + onprem-nested → Hub):
//      createHubVpnGateway = false → infra/network/ で作成済みの Hub GW を参照
//      接続名が -nested サフィックスで分離されるため既存 onprem に影響なし
//
// Deployment:
//   $env:VPN_SHARED_KEY = '<your-shared-key>'
//   az deployment sub create -l japaneast -f vpn-deploy.bicep -p vpn-deploy.bicepparam
//
// Note: VPN Gateway deployment takes 30-45 minutes.
// ============================================================================

targetScope = 'subscription'

@description('Deployment region')
param location string = deployment().location

@secure()
@description('Shared key for VPN authentication')
param sharedKey string

@description('On-premises resource group name')
param onpremResourceGroupName string = 'rg-onprem-nested'

@description('Hub resource group name')
param hubResourceGroupName string = 'rg-hub'

@description('On-premises VNet name')
param onpremVnetName string = 'vnet-onprem'

@description('VPN Gateway SKU')
param vpnGatewaySku string = 'VpnGw1AZ'

@description('Cloud address prefixes to route from on-prem via VPN')
param cloudAddressPrefixes array = [
  '10.10.0.0/16' // Hub
  '10.20.0.0/16' // Spoke1 (Rehost)
  '10.21.0.0/16' // Spoke2 (DB PaaS)
  '10.22.0.0/16' // Spoke3 (Container)
  '10.23.0.0/16' // Spoke4 (Full PaaS)
]

@description('Create Hub VPN Gateway (true=standalone, false=use existing from infra/network/)')
param createHubVpnGateway bool = false

// ============================================================================
// Existing Resource Groups
// ============================================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: onpremResourceGroupName
}

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: hubResourceGroupName
}

// ============================================================================
// On-prem Network Preparation
// - Add GatewaySubnet to vnet-onprem
// - Add cloud routes to rt-block-internet
// ============================================================================

module onpremVpnRoutes 'modules/vpn-routes.bicep' = {
  scope: rgOnprem
  name: 'deploy-onprem-vpn-routes'
  params: {
    vnetName: onpremVnetName
    routeTableName: 'rt-block-internet'
    cloudAddressPrefixes: cloudAddressPrefixes
  }
}

// ============================================================================
// VPN Gateways
// - On-prem: always newly created (takes ~30-45 min)
// - Hub: conditional — create new (standalone) or use existing (dual)
// ============================================================================

@description('Hub VNet name')
param hubVnetName string = 'vnet-hub'

@description('Hub VPN Gateway name')
param hubVpnGatewayName string = 'vpngw-hub'

// Hub VPN Gateway resource ID (deterministic — valid for both new and existing)
var hubGatewayId = '${rgHub.id}/providers/Microsoft.Network/virtualNetworkGateways/${hubVpnGatewayName}'

module onpremVpnGateway 'modules/vpn-gateway.bicep' = {
  scope: rgOnprem
  name: 'deploy-vgw-onprem'
  params: {
    location: location
    gatewayName: 'vgw-onprem'
    publicIpName: 'pip-vgw-onprem'
    vnetName: onpremVnetName
    sku: vpnGatewaySku
  }
  dependsOn: [
    onpremVpnRoutes // GatewaySubnet must exist first
  ]
}

// Hub VPN Gateway — create only in standalone mode
module hubVpnGatewayNew 'modules/vpn-gateway.bicep' = if (createHubVpnGateway) {
  scope: rgHub
  name: 'deploy-vpngw-hub'
  params: {
    location: location
    gatewayName: hubVpnGatewayName
    publicIpName: 'pip-vpngw-hub'
    vnetName: hubVnetName
    sku: vpnGatewaySku
  }
}

// ============================================================================
// VPN Connections (Vnet2Vnet, bidirectional)
// ============================================================================

module connectionOnpremToHub 'modules/vpn-connection.bicep' = {
  scope: rgOnprem
  name: 'deploy-cn-onprem-nested-to-hub'
  params: {
    location: location
    connectionName: 'cn-onprem-nested-to-hub'
    localGatewayId: onpremVpnGateway.outputs.gatewayId
    remoteGatewayId: hubGatewayId
    sharedKey: sharedKey
  }
  dependsOn: [hubVpnGatewayNew] // no-op when createHubVpnGateway=false
}

module connectionHubToOnprem 'modules/vpn-connection.bicep' = {
  scope: rgHub
  name: 'deploy-cn-hub-to-onprem-nested'
  params: {
    location: location
    connectionName: 'cn-hub-to-onprem-nested'
    localGatewayId: hubGatewayId
    remoteGatewayId: onpremVpnGateway.outputs.gatewayId
    sharedKey: sharedKey
  }
  dependsOn: [hubVpnGatewayNew] // no-op when createHubVpnGateway=false
}

// ============================================================================
// Outputs
// ============================================================================

output onpremVpnGatewayId string = onpremVpnGateway.outputs.gatewayId
output hubVpnGatewayId string = hubGatewayId
output connectionOnpremToHubId string = connectionOnpremToHub.outputs.connectionId
output connectionHubToOnpremId string = connectionHubToOnprem.outputs.connectionId
