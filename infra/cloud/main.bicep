// ============================================================
// Compatibility wrapper for unified initial setup
// ============================================================
// 既存の `infra/cloud/main.bicep` パスを維持しつつ、
// 正式エントリポイント `infra/main.bicep` を呼び出します。
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

module unifiedInitialSetup '../main.bicep' = {
  name: 'deploy-unified-initial-setup'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainName: domainName
    vpnSharedKey: vpnSharedKey
    deployFirewall: deployFirewall
    deployVpnGateway: deployVpnGateway
    deployBastion: deployBastion
  }
}

output onpremResourceGroupName string = unifiedInitialSetup.outputs.onpremResourceGroupName
output hubResourceGroupName string = unifiedInitialSetup.outputs.hubResourceGroupName
output hubGatewayPublicIp string = unifiedInitialSetup.outputs.hubGatewayPublicIp
output onpremVpnGatewayName string = unifiedInitialSetup.outputs.onpremVpnGatewayName
