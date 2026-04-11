// ============================================================================
// On-prem VPN Gateway Only (Phase 1)
//
// Deploys ONLY the on-prem side VPN Gateway without establishing connections.
// Use this when connecting to an external environment (real on-prem, AWS, GCP)
// where the remote side is provisioned separately.
//
// What this deploys:
//   - GatewaySubnet added to vnet-onprem
//   - Cloud routes added to rt-block-internet
//   - VPN Gateway (vgw-onprem) with Public IP
//
// After deployment, use the output Public IP to configure the remote side,
// then run Deploy-Vpn.ps1 or create connections manually.
//
// Usage:
//   az deployment sub create -l japaneast -f onprem-gateway.bicep -p onprem-gateway.bicepparam
//
// Note: VPN Gateway deployment takes 30-45 minutes.
// ============================================================================

targetScope = 'subscription'

@description('Deployment region')
param location string = deployment().location

@description('On-premises resource group name')
param onpremResourceGroupName string = 'rg-onprem-nested'

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
// Existing Resource Group
// ============================================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: onpremResourceGroupName
}

// VNet Resource ID
var onpremVnetId = '${rgOnprem.id}/providers/Microsoft.Network/virtualNetworks/${onpremVnetName}'

// ============================================================================
// Network Preparation: GatewaySubnet + Routes
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
// VPN Gateway
// ============================================================================

module onpremVpnGateway 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = {
  scope: rgOnprem
  name: 'deploy-vgw-onprem'
  params: {
    name: 'vgw-onprem'
    location: location
    gatewayType: 'Vpn'
    skuName: vpnGatewaySku
    virtualNetworkResourceId: onpremVnetId
    clusterSettings: { clusterMode: 'activePassiveNoBgp' }
  }
  dependsOn: [
    onpremVpnRoutes
  ]
}

// ============================================================================
// Outputs — use these to configure the remote side
// ============================================================================

output onpremVpnGatewayId string = onpremVpnGateway.outputs.resourceId
output onpremVpnGatewayName string = onpremVpnGateway.outputs.name
