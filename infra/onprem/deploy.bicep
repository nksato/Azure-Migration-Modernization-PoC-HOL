// ============================================================
// 疑似オンプレミス環境 — サブスクリプションスコープ ラッパー
// ============================================================
// リソースグループの作成を含めて一括デプロイするためのエントリポイント。
// 内部で main.bicep をモジュールとして呼び出します。
//
// 使い方:
//   az deployment sub create \
//     --location japaneast \
//     --template-file infra/onprem/deploy.bicep \
//     --parameters adminPassword='<パスワード>' vpnSharedKey='<共有キー>'
// ============================================================

targetScope = 'subscription'

@description('デプロイリージョン')
param location string = 'japaneast'

@description('管理者ユーザー名')
param adminUsername string = 'labadmin'

@description('管理者パスワード')
@secure()
param adminPassword string

@description('Active Directory ドメイン名')
param domainName string = 'lab.local'

@description('VPN 共有キー (S2S 接続用)')
@secure()
param vpnSharedKey string

@description('接続先 Azure VPN Gateway のパブリック IP アドレス (空の場合 S2S 接続リソースはスキップ)')
param remoteGatewayIp string = ''

@description('接続先 Azure 側のアドレス空間')
param remoteAddressPrefix string = '10.10.0.0/16'

@description('リソースグループ名')
param resourceGroupName string = 'rg-onprem'

// ============================================================
// リソースグループ
// ============================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    Environment: 'PoC'
    Purpose: 'OnPrem-Simulation'
  }
}

// ============================================================
// 疑似オンプレ環境 (RG スコープのモジュール呼び出し)
// ============================================================

module onpremEnvironment 'main.bicep' = {
  name: 'deploy-onprem-environment'
  scope: rgOnprem
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainName: domainName
    vpnSharedKey: vpnSharedKey
    remoteGatewayIp: remoteGatewayIp
    remoteAddressPrefix: remoteAddressPrefix
  }
}
