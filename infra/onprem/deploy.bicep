// ============================================================
// 疑似オンプレミス環境 — サブスクリプションスコープ ラッパー
// ============================================================
// リソースグループの作成を含めて一括デプロイするためのエントリポイント。
// 内部で main.bicep をモジュールとして呼び出します。
// VPN Gateway は Step 4 (infra/vpn/main.bicep) で別途デプロイします。
//
// 使い方:
//   az deployment sub create \
//     --location japaneast \
//     --template-file infra/onprem/deploy.bicep \
//     --parameters adminPassword='<パスワード>'
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
  }
}
