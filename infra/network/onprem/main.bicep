// ============================================================
// VPN Gateway 配置・接続
// ============================================================
// 疑似オンプレと Hub の両方に VPN Gateway をデプロイし、
// S2S 接続を確立します。
// Subscription スコープで実行し、既存 VNet の GatewaySubnet を使用。
//
// Usage patterns:
//   A) Standalone (default): createHubVpnGateway = true
//      → Hub VPN GW を新規作成 + Peering Gateway Transit 設定
//   B) Dual (Hub GW 既存): createHubVpnGateway = false
//      → 既存 Hub GW を参照
//
// 非ネスト / ネスト Hyper-V の切替は bicepparam で行う
// ============================================================

targetScope = 'subscription'

// ============================================================
// Parameters
// ============================================================

@description('デプロイリージョン')
param location string = deployment().location

@description('VPN 共有キー (S2S 接続用)')
@secure()
param vpnSharedKey string

@description('オンプレ側リソースグループ名')
param onpremResourceGroupName string = 'rg-onprem'

@description('Hub 側リソースグループ名')
param hubResourceGroupName string = 'rg-hub'

@description('オンプレ側 VNet 名')
param onpremVnetName string = 'vnet-onprem'

@description('Hub 側 VNet 名')
param hubVnetName string = 'vnet-hub'

@description('GatewaySubnet アドレスプレフィックス')
param gatewaySubnetPrefix string = '10.0.255.0/27'

@description('VPN Gateway SKU')
param vpnGatewaySku string = 'VpnGw1AZ'

@description('オンプレ側 VPN Gateway 名')
param onpremVpnGatewayName string = 'vgw-onprem'

@description('Hub 側 VPN Gateway 名')
param hubVpnGatewayName string = 'vpngw-hub'

@description('Cloud 側アドレスプレフィックス (LGW 用)')
param cloudAddressPrefixes array = [
  '10.10.0.0/16' // Hub
  '10.20.0.0/16' // Spoke1
  '10.21.0.0/16' // Spoke2
  '10.22.0.0/16' // Spoke3
  '10.23.0.0/16' // Spoke4
]

@description('オンプレ側アドレスプレフィックス (LGW 用)')
param onpremAddressPrefix string = '10.0.0.0/16'

@description('Hub VPN Gateway を新規作成するか (false=既存を参照)')
param createHubVpnGateway bool = true

@description('オンプレ識別子 (Hub 側リソース名の衝突回避用)')
param onpremIdentifier string = 'onprem'

// ============================================================
// Existing Resource Groups
// ============================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: onpremResourceGroupName
}

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: hubResourceGroupName
}

// Tags
var commonTags = {
  Environment: 'PoC'
  Project: 'Migration-Handson'
  SecurityControl: 'Ignore'
}

// VNet Resource IDs
var onpremVnetId = '${rgOnprem.id}/providers/Microsoft.Network/virtualNetworks/${onpremVnetName}'
var hubVnetId = '${rgHub.id}/providers/Microsoft.Network/virtualNetworks/${hubVnetName}'

// Hub VPN Gateway resource ID (deterministic — valid for both new and existing)
var hubGatewayId = '${rgHub.id}/providers/Microsoft.Network/virtualNetworkGateways/${hubVpnGatewayName}'

// ============================================================
// オンプレ側: GatewaySubnet 追加
// ============================================================

module onpremGatewaySubnet 'modules/onprem-gateway-subnet.bicep' = {
  scope: rgOnprem
  name: 'deploy-onprem-gateway-subnet'
  params: {
    vnetName: onpremVnetName
    gatewaySubnetPrefix: gatewaySubnetPrefix
  }
}

// ============================================================
// オンプレ側: VPN Gateway (AVM)
// ============================================================

module onpremVpnGateway 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = {
  scope: rgOnprem
  name: 'deploy-onprem-vpn-gateway'
  params: {
    name: onpremVpnGatewayName
    location: location
    gatewayType: 'Vpn'
    skuName: vpnGatewaySku
    tags: commonTags
    virtualNetworkResourceId: onpremVnetId
    clusterSettings: { clusterMode: 'activePassiveNoBgp' }
    primaryPublicIPName: '${onpremVpnGatewayName}-pip1'
  }
  dependsOn: [onpremGatewaySubnet]
}

// ============================================================
// Hub 側: VPN Gateway (AVM, 条件付き)
// ============================================================

module hubVpnGateway 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = if (createHubVpnGateway) {
  scope: rgHub
  name: 'deploy-hub-vpn-gateway'
  params: {
    name: hubVpnGatewayName
    location: location
    gatewayType: 'Vpn'
    skuName: vpnGatewaySku
    tags: commonTags
    virtualNetworkResourceId: hubVnetId
    clusterSettings: { clusterMode: 'activePassiveNoBgp' }
    domainNameLabel: ['${hubVpnGatewayName}-${uniqueString(subscription().subscriptionId)}']
    primaryPublicIPName: '${hubVpnGatewayName}-pip1'
  }
}

// ============================================================
// Public IP 取得 (Hub — 新規/既存どちらでも対応)
// ============================================================

module getHubPip 'modules/get-pip-ip.bicep' = {
  scope: rgHub
  name: 'get-hub-vpn-pip'
  params: {
    pipName: '${hubVpnGatewayName}-pip1'
  }
  dependsOn: [hubVpnGateway]
}

// ============================================================
// Local Network Gateway (オンプレ側 — Hub を表す)
// ============================================================

module lgwHub 'br/public:avm/res/network/local-network-gateway:0.4.0' = {
  scope: rgOnprem
  name: 'deploy-lgw-hub'
  params: {
    name: 'lgw-hub'
    location: location
    tags: commonTags
    localGatewayPublicIpAddress: getHubPip.outputs.ipAddress
    localNetworkAddressSpace: {
      addressPrefixes: cloudAddressPrefixes
    }
  }
}

// ============================================================
// S2S 接続 (オンプレ → Hub)
// ============================================================

module cnOnpremToHub 'br/public:avm/res/network/connection:0.1.7' = {
  scope: rgOnprem
  name: 'deploy-cn-${onpremIdentifier}-to-hub'
  params: {
    name: 'cn-${onpremIdentifier}-to-hub'
    location: location
    tags: commonTags
    virtualNetworkGateway1: {
      id: onpremVpnGateway.outputs.resourceId
    }
    localNetworkGateway2ResourceId: lgwHub.outputs.resourceId
    vpnSharedKey: vpnSharedKey
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
  }
}

// ============================================================
// Local Network Gateway (Hub 側 — オンプレを表す)
// ============================================================

module lgwOnprem 'br/public:avm/res/network/local-network-gateway:0.4.0' = {
  scope: rgHub
  name: 'deploy-lgw-${onpremIdentifier}'
  params: {
    name: 'lgw-${onpremIdentifier}'
    location: location
    tags: commonTags
    localGatewayPublicIpAddress: onpremVpnGateway.outputs.primaryPublicIpAddress!
    localNetworkAddressSpace: {
      addressPrefixes: [
        onpremAddressPrefix
      ]
    }
  }
}

// ============================================================
// S2S 接続 (Hub → オンプレ)
// ============================================================

module cnHubToOnprem 'br/public:avm/res/network/connection:0.1.7' = {
  scope: rgHub
  name: 'deploy-cn-hub-to-${onpremIdentifier}'
  params: {
    name: 'cn-hub-to-${onpremIdentifier}'
    location: location
    tags: commonTags
    virtualNetworkGateway1: {
      id: hubGatewayId
    }
    localNetworkGateway2ResourceId: lgwOnprem.outputs.resourceId
    vpnSharedKey: vpnSharedKey
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
  }
}

// ============================================================
// Peering 更新: Gateway Transit を有効化 (standalone mode only)
// ============================================================

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
  dependsOn: [hubVpnGateway]
}

// ============================================================
// Outputs
// ============================================================

output onpremVpnGatewayId string = onpremVpnGateway.outputs.resourceId
output onpremVpnGatewayPublicIp string = onpremVpnGateway.outputs.primaryPublicIpAddress!
output hubVpnGatewayId string = hubGatewayId
output hubVpnGatewayPublicIp string = getHubPip.outputs.ipAddress
output connectionOnpremToHubId string = cnOnpremToHub.outputs.resourceId
output connectionHubToOnpremId string = cnHubToOnprem.outputs.resourceId
