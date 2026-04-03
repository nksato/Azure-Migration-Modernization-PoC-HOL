// ============================================================
// Azure Migration & Modernization PoC - Unified Initial Setup
// ============================================================
// 一括デプロイ用の正式エントリポイント
// `infra/cloud/main.bicep` と `infra/onprem/main.bicep` を呼び出し、
// 段階実行（方法 B）と同じ構成・命名に揃えて初期環境を作成します。
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

@description('VPN 共有キー (方法 B の Step 1 / Step 3 と同じ値)')
@secure()
param vpnSharedKey string

@description('Azure Firewall をデプロイするか')
param deployFirewall bool = true

@description('Hub 側 Azure VPN Gateway をデプロイするか')
param deployVpnGateway bool = true

@description('Hub 側 Azure Bastion をデプロイするか')
param deployBastion bool = true

var onpremResourceGroupName = 'rg-onprem'
var hubAddressPrefix = '10.10.0.0/16'

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: onpremResourceGroupName
  location: location
}

module cloudFoundation 'cloud/main.bicep' = {
  name: 'deploy-cloud-foundation'
  params: {
    location: location
    deployFirewall: deployFirewall
    deployBastion: deployBastion
    deployVpnGateway: deployVpnGateway
  }
}

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: 'rg-hub'
}

resource hubVpnPublicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' existing = if (deployVpnGateway) {
  scope: rgHub
  name: 'pip-vgw-hub'
}

var hubGatewayIp = deployVpnGateway ? reference(hubVpnPublicIp.id, '2024-01-01').ipAddress : ''

module onpremEnvironment 'onprem/main.bicep' = {
  name: 'deploy-onprem-environment'
  scope: rgOnprem
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainName: domainName
    vpnSharedKey: vpnSharedKey
    remoteGatewayIp: hubGatewayIp
    remoteAddressPrefix: hubAddressPrefix
  }
  dependsOn: [
    cloudFoundation
  ]
}

output onpremResourceGroupName string = rgOnprem.name
output hubResourceGroupName string = rgHub.name
output hubGatewayPublicIp string = hubGatewayIp
output onpremVpnGatewayName string = 'OnPrem-VpnGw'
output dnsResolverInboundSubnet string = '10.10.5.0/28 (snet-dns-inbound)'
