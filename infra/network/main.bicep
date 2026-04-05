// ============================================================
// Step 4: VPN Gateway 配置・接続
// ============================================================
// 疑似オンプレ (rg-onprem) と Hub (rg-hub) の両方に VPN Gateway を
// デプロイし、S2S 接続を確立します。
// Subscription スコープで実行し、既存 VNet の GatewaySubnet を使用します。
// ============================================================

targetScope = 'subscription'

@description('デプロイリージョン')
param location string = 'japaneast'

@description('VPN 共有キー (S2S 接続用)')
@secure()
param vpnSharedKey string

// ============================================================
// 既存リソースグループの参照
// ============================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: 'rg-onprem'
}

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: 'rg-hub'
}

// タグ定義
var commonTags = {
  Environment: 'PoC'
  SecurityControl: 'ignore'
}

// ============================================================
// オンプレ側: GatewaySubnet 追加 + VPN Gateway
// ============================================================

module onpremVpnGateway 'modules/onprem-vpn-gateway.bicep' = {
  scope: rgOnprem
  name: 'deploy-onprem-vpn-gateway'
  params: {
    location: location
    tags: commonTags
    vnetName: 'vnet-onprem'
  }
}

// ============================================================
// Hub 側: VPN Gateway (AVM モジュール使用)
// ============================================================

module hubVpnGateway 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = {
  scope: rgHub
  params: {
    name: 'vpngw-hub'
    location: location
    gatewayType: 'Vpn'
    skuName: 'VpnGw1AZ'
    tags: commonTags
    virtualNetworkResourceId: hubVnetId
    clusterSettings: { clusterMode: 'activePassiveNoBgp' }
    domainNameLabel: ['vpngw-hub-${uniqueString(subscription().subscriptionId)}']
  }
}

// Hub VNet の Resource ID を構築
var hubVnetId = resourceId('rg-hub', 'Microsoft.Network/virtualNetworks', 'vnet-hub')

// ============================================================
// Hub 側 VPN Gateway の Public IP を取得
// ============================================================

module getHubVpnPip 'modules/get-pip-ip.bicep' = {
  scope: rgHub
  name: 'get-hub-vpn-pip'
  params: {
    pipName: 'vpngw-hub-pip1'
  }
  dependsOn: [hubVpnGateway]
}

// ============================================================
// S2S 接続 (オンプレ側に Local Network Gateway + Connection を作成)
// ============================================================

module vpnConnection 'modules/vpn-connection.bicep' = {
  scope: rgOnprem
  name: 'deploy-vpn-connection'
  params: {
    location: location
    tags: commonTags
    vpnSharedKey: vpnSharedKey
    onpremVpnGatewayId: onpremVpnGateway.outputs.vpnGatewayId
    remoteGatewayIp: getHubVpnPip.outputs.ipAddress
    remoteAddressPrefix: '10.10.0.0/16'
  }
}

// ============================================================
// Peering 更新: Gateway Transit を有効化
// ============================================================

module hubPeeringUpdate 'modules/update-hub-peering.bicep' = {
  scope: rgHub
  name: 'update-hub-peering-gateway-transit'
  params: {
    location: location
    hubVnetResourceId: hubVnetId
    spoke1VnetId: resourceId('rg-spoke1', 'Microsoft.Network/virtualNetworks', 'vnet-spoke1')
    spoke2VnetId: resourceId('rg-spoke2', 'Microsoft.Network/virtualNetworks', 'vnet-spoke2')
    spoke3VnetId: resourceId('rg-spoke3', 'Microsoft.Network/virtualNetworks', 'vnet-spoke3')
    spoke4VnetId: resourceId('rg-spoke4', 'Microsoft.Network/virtualNetworks', 'vnet-spoke4')
  }
  dependsOn: [hubVpnGateway]
}

// ============================================================
// Outputs
// ============================================================

output onpremVpnGatewayPublicIp string = onpremVpnGateway.outputs.vpnGatewayPublicIp
output hubVpnGatewayPublicIp string = getHubVpnPip.outputs.ipAddress
