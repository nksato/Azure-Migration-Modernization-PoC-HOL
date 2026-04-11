// ============================================================================
// VPN Deploy - On-premises Nested (rg-onprem-nested) <-> Hub (rg-hub)
//
// One-shot deployment: both VPN Gateways + bidirectional S2S connections.
//
// Architecture:
//   rg-onprem-nested             rg-hub
//   ┌──────────────────┐         ┌──────────────────┐
//   │ vnet-onprem-nested│         │ vnet-hub          │
//   │ 10.1.0.0/16       │         │ 10.10.0.0/16      │
//   │                   │         │                   │
//   │ ┌───────────────┐ │   S2S   │ ┌───────────────┐ │
//   │ │ GatewaySubnet │◄├─────────┤►│ GatewaySubnet │ │
//   │ │ 10.1.255.0/27 │ │  IPsec  │ │10.10.255.0/27 │ │
//   │ └───────────────┘ │         │ └───────────────┘ │
//   │                   │         │                   │
//   │ lgw-hub           │         │ lgw-onprem-nested │
//   │ (Hub の PIP 参照)  │         │ (OnPrem の PIP 参照)│
//   └──────────────────┘         └──────────────────┘
//
// Prerequisites:
//   1. On-premises nested environment deployed (onprem-nested/main.bicep)
//   2. Cloud environment deployed (cloud/main.bicep)
//      - rg-hub with vnet-hub (GatewaySubnet 含む)
//      - rg-spoke1 ~ rg-spoke4 with vnet-spoke1 ~ vnet-spoke4
//
// Usage patterns:
//   A) Standalone (default — onprem-nested only -> Hub):
//      createHubVpnGateway = true  -> Hub VPN GW を新規作成 + Peering Gateway Transit 設定
//
//   B) Dual (onprem + onprem-nested -> Hub):
//      createHubVpnGateway = false -> infra/network/onprem/ で作成済みの Hub GW を参照
//
// Deployment:
//   $env:VPN_SHARED_KEY = '<your-shared-key>'
//   az deployment sub create -l japaneast -f main.bicep -p main.bicepparam
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
param onpremVnetName string = 'vnet-onprem-nested'

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

@description('On-premises address prefix (for LGW on Hub side)')
param onpremAddressPrefix string = '10.1.0.0/16'

@description('Create Hub VPN Gateway (true=standalone, false=use existing from infra/network/onprem/)')
param createHubVpnGateway bool = true

@description('Hub VNet name')
param hubVnetName string = 'vnet-hub'

@description('Hub VPN Gateway name')
param hubVpnGatewayName string = 'vpngw-hub'

// ============================================================================
// Existing Resource Groups
// ============================================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: onpremResourceGroupName
}

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: hubResourceGroupName
}

// Hub VPN Gateway resource ID (deterministic — valid for both new and existing)
var hubGatewayId = '${rgHub.id}/providers/Microsoft.Network/virtualNetworkGateways/${hubVpnGatewayName}'

// VNet Resource IDs
var onpremVnetId = '${rgOnprem.id}/providers/Microsoft.Network/virtualNetworks/${onpremVnetName}'
var hubVnetId = '${rgHub.id}/providers/Microsoft.Network/virtualNetworks/${hubVnetName}'

// Tags
var commonTags = {
  Environment: 'PoC'
  Project: 'Migration-Handson'
  SecurityControl: 'Ignore'
}

// ============================================================================
// Phase 1: On-prem Network Preparation + VPN Gateway
// ============================================================================

module onpremVpnRoutes 'modules/vpn-routes.bicep' = {
  scope: rgOnprem
  name: 'deploy-onprem-vpn-routes'
  params: {
    vnetName: onpremVnetName
  }
}

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
    tags: commonTags
  }
  dependsOn: [
    onpremVpnRoutes // GatewaySubnet must exist first
  ]
}

// ============================================================================
// Phase 2: Hub VPN Gateway (conditional)
// ============================================================================

module hubVpnGatewayNew 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = if (createHubVpnGateway) {
  scope: rgHub
  name: 'deploy-vpngw-hub'
  params: {
    name: hubVpnGatewayName
    location: location
    gatewayType: 'Vpn'
    skuName: vpnGatewaySku
    virtualNetworkResourceId: hubVnetId
    clusterSettings: { clusterMode: 'activePassiveNoBgp' }
    domainNameLabel: ['vpngw-hub-${uniqueString(subscription().subscriptionId)}']
    tags: commonTags
  }
}

// ============================================================================
// Phase 3a: Public IP retrieval
// ============================================================================

module getOnpremPip 'modules/get-pip-ip.bicep' = {
  scope: rgOnprem
  name: 'get-onprem-vpn-pip'
  params: {
    pipName: 'vgw-onprem-pip1'
  }
  dependsOn: [onpremVpnGateway]
}

module getHubPip 'modules/get-pip-ip.bicep' = {
  scope: rgHub
  name: 'get-hub-vpn-pip'
  params: {
    pipName: '${hubVpnGatewayName}-pip1'
  }
  dependsOn: [hubVpnGatewayNew]
}

// ============================================================================
// Phase 3b: Local Network Gateways (S2S requires LGW to represent remote side)
// ============================================================================

module lgwHub 'modules/local-network-gateway.bicep' = {
  scope: rgOnprem
  name: 'deploy-lgw-hub'
  params: {
    name: 'lgw-hub'
    location: location
    gatewayIpAddress: getHubPip.outputs.ipAddress
    addressPrefixes: cloudAddressPrefixes
    tags: commonTags
  }
}

module lgwOnprem 'modules/local-network-gateway.bicep' = {
  scope: rgHub
  name: 'deploy-lgw-onprem-nested'
  params: {
    name: 'lgw-onprem-nested'
    location: location
    gatewayIpAddress: getOnpremPip.outputs.ipAddress
    addressPrefixes: [onpremAddressPrefix]
    tags: commonTags
  }
}

// ============================================================================
// Phase 3c: S2S VPN Connections (IPsec, bidirectional)
// ============================================================================

module connectionOnpremToHub 'br/public:avm/res/network/connection:0.1.7' = {
  scope: rgOnprem
  name: 'deploy-cn-onprem-nested-to-hub'
  params: {
    name: 'cn-onprem-nested-to-hub'
    virtualNetworkGateway1: { id: onpremVpnGateway.outputs.resourceId }
    localNetworkGateway2ResourceId: lgwHub.outputs.resourceId
    connectionType: 'IPsec'
    vpnSharedKey: sharedKey
    tags: commonTags
  }
}

module connectionHubToOnprem 'br/public:avm/res/network/connection:0.1.7' = {
  scope: rgHub
  name: 'deploy-cn-hub-to-onprem-nested'
  params: {
    name: 'cn-hub-to-onprem-nested'
    virtualNetworkGateway1: {
      id: createHubVpnGateway ? hubVpnGatewayNew.outputs.resourceId : hubGatewayId
    }
    localNetworkGateway2ResourceId: lgwOnprem.outputs.resourceId
    connectionType: 'IPsec'
    vpnSharedKey: sharedKey
    tags: commonTags
  }
}

// ============================================================================
// Phase 4: Hub-Spoke Peering Gateway Transit (standalone mode only)
// ============================================================================

module hubPeeringUpdate 'modules/update-hub-peering.bicep' = if (createHubVpnGateway) {
  scope: rgHub
  name: 'update-hub-peering-gateway-transit'
  params: {
    location: location
    hubVnetResourceId: hubVnetId
    spoke1VnetId: '${subscription().id}/resourceGroups/rg-spoke1/providers/Microsoft.Network/virtualNetworks/vnet-spoke1'
    spoke2VnetId: '${subscription().id}/resourceGroups/rg-spoke2/providers/Microsoft.Network/virtualNetworks/vnet-spoke2'
    spoke3VnetId: '${subscription().id}/resourceGroups/rg-spoke3/providers/Microsoft.Network/virtualNetworks/vnet-spoke3'
    spoke4VnetId: '${subscription().id}/resourceGroups/rg-spoke4/providers/Microsoft.Network/virtualNetworks/vnet-spoke4'
  }
  dependsOn: [hubVpnGatewayNew]
}

// ============================================================================
// Outputs
// ============================================================================

output onpremVpnGatewayId string = onpremVpnGateway.outputs.resourceId
output onpremVpnGatewayPip string = getOnpremPip.outputs.ipAddress
output hubVpnGatewayId string = hubGatewayId
output hubVpnGatewayPip string = getHubPip.outputs.ipAddress
output connectionOnpremToHubId string = connectionOnpremToHub.outputs.resourceId
output connectionHubToOnpremId string = connectionHubToOnprem.outputs.resourceId
