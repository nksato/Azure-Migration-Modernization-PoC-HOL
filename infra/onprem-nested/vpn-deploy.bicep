// ============================================================================
// VPN Deploy - On-premises (rg-onprem-migration) <-> Hub (rg-hub)
//
// Architecture:
//   rg-onprem-migration          rg-hub
//   ┌──────────────────┐         ┌──────────────────┐
//   │ vnet-onprem       │         │ vnet-hub          │
//   │ 10.0.0.0/16       │         │ 10.10.0.0/16      │
//   │                   │         │                   │
//   │ ┌───────────────┐ │   VPN   │ ┌───────────────┐ │
//   │ │ GatewaySubnet │◄├─────────┤►│ GatewaySubnet │ │
//   │ │ 10.0.255.0/27 │ │  IPsec  │ │10.10.255.0/27 │ │
//   │ └───────────────┘ │         │ └───────────────┘ │
//   └──────────────────┘         └──────────────────┘
//
// Prerequisites:
//   1. On-premises environment deployed (main.bicep)
//   2. Cloud environment deployed (Azure-Migration-Modernization-PoC-HOL)
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
param onpremResourceGroupName string = 'rg-onprem-migration'

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
// - On-prem: newly created (takes ~30-45 min)
// - Hub: newly created (GatewaySubnet already exists in vnet-hub)
// ============================================================================

@description('Hub VNet name')
param hubVnetName string = 'vnet-hub'

module onpremVpnGateway 'modules/vpn-gateway.bicep' = {
  scope: rgOnprem
  name: 'deploy-vpngw-onprem'
  params: {
    location: location
    gatewayName: 'vpngw-onprem'
    publicIpName: 'pip-vpngw-onprem'
    vnetName: onpremVnetName
    sku: vpnGatewaySku
  }
  dependsOn: [
    onpremVpnRoutes // GatewaySubnet must exist first
  ]
}

module hubVpnGateway 'modules/vpn-gateway.bicep' = {
  scope: rgHub
  name: 'deploy-vpngw-hub'
  params: {
    location: location
    gatewayName: 'vpngw-hub'
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
  name: 'deploy-cn-onprem-to-hub'
  params: {
    location: location
    connectionName: 'cn-onprem-to-hub'
    localGatewayId: onpremVpnGateway.outputs.gatewayId
    remoteGatewayId: hubVpnGateway.outputs.gatewayId
    sharedKey: sharedKey
  }
}

module connectionHubToOnprem 'modules/vpn-connection.bicep' = {
  scope: rgHub
  name: 'deploy-cn-hub-to-onprem'
  params: {
    location: location
    connectionName: 'cn-hub-to-onprem'
    localGatewayId: hubVpnGateway.outputs.gatewayId
    remoteGatewayId: onpremVpnGateway.outputs.gatewayId
    sharedKey: sharedKey
  }
}

// ============================================================================
// Outputs
// ============================================================================

output onpremVpnGatewayId string = onpremVpnGateway.outputs.gatewayId
output hubVpnGatewayId string = hubVpnGateway.outputs.gatewayId
output connectionOnpremToHubId string = connectionOnpremToHub.outputs.connectionId
output connectionHubToOnpremId string = connectionHubToOnprem.outputs.connectionId
