// ============================================================
// 疑似オンプレミス環境 — サブスクリプションスコープ エントリポイント
// ============================================================
// リソースグループの作成を含めて一括デプロイするためのエントリポイント。
// 内部で resources.bicep をローカルモジュールとして呼び出します。
// VPN Gateway は Step 4 (infra/network/main.bicep) で別途デプロイします。
//
// AVM (Azure Verified Modules) ではなくローカルモジュールを使用する理由:
//   - VM 拡張の protectedSettings を AVM 用オブジェクト形式に変換する煩雑さ
//   - AD 構築→ドメイン参加など拡張間の依存関係制御が直感的に書けない
// 参考: https://azure.github.io/Azure-Verified-Modules/
//
// 使い方:
//   az deployment sub create \
//     --location japaneast \
//     --template-file infra/onprem/main.bicep \
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

// ============================================================
// リソースグループ
// ============================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-onprem'
  location: location
  tags: {
    Environment: 'PoC'
    Purpose: 'OnPrem-Simulation'
  }
}

// ============================================================
// 疑似オンプレ環境 (RG スコープのモジュール呼び出し)
// ============================================================

module onpremEnvironment 'resources.bicep' = {
  name: 'deploy-onprem-environment'
  scope: rgOnprem
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainName: domainName
  }
}
