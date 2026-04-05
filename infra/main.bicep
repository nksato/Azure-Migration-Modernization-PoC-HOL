// ============================================================
// Azure Migration & Modernization PoC - Unified Initial Setup
// ============================================================
// 一括デプロイ用の正式エントリポイント
// Step 1 (onprem) → Step 3 (cloud) → Step 4 (vpn) を順次呼び出し、
// 段階実行（方法 B）と同じ構成・命名に揃えて初期環境を作成します。
// DNS 転送設定 (Step 5) は VPN 確立後にスクリプトで実行してください。
// ============================================================

targetScope = 'subscription'

@description('デプロイリージョン')
param location string = 'japaneast'

@description('VM 管理者ユーザー名')
param adminUsername string = 'labadmin'

@description('VM 管理者パスワード')
@secure()
param adminPassword string

@description('Active Directory ドメイン名')
param domainName string = 'lab.local'

@description('VPN 共有キー (S2S 接続用)')
@secure()
param vpnSharedKey string

@description('Azure Firewall をデプロイするか')
param deployFirewall bool = true

@description('Hub 側 Azure VPN Gateway をデプロイするか')
param deployVpnGateway bool = true

@description('Hub 側 Azure Bastion をデプロイするか')
param deployBastion bool = true

var onpremResourceGroupName = 'rg-onprem'

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: onpremResourceGroupName
  location: location
  tags: {
    Environment: 'PoC'
    Purpose: 'OnPrem-Simulation'
  }
}

// Phase 1: クラウド基盤とオンプレ基盤を並列デプロイ
module cloudFoundation 'cloud/main.bicep' = {
  name: 'deploy-cloud-foundation'
  params: {
    location: location
    deployFirewall: deployFirewall
    deployBastion: deployBastion
  }
}

module onpremBase 'onprem/resources.bicep' = {
  name: 'deploy-onprem-base'
  scope: rgOnprem
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainName: domainName
  }
}

// Phase 2: 両方の VPN GW を作成し S2S 接続
module vpnSetup 'network/main.bicep' = if (deployVpnGateway) {
  name: 'deploy-vpn-setup'
  dependsOn: [onpremBase, cloudFoundation]
  params: {
    location: location
    vpnSharedKey: vpnSharedKey
  }
}

output onpremResourceGroupName string = rgOnprem.name
output hubResourceGroupName string = 'rg-hub'
output hubGatewayPublicIp string = deployVpnGateway ? vpnSetup.outputs.hubVpnGatewayPublicIp : ''
output onpremVpnGatewayPublicIp string = deployVpnGateway ? vpnSetup.outputs.onpremVpnGatewayPublicIp : ''
output dnsResolverInboundSubnet string = '10.10.5.0/28 (snet-dns-inbound)'
