# Phase 5a: Rehost（Lift & Shift）— Spoke1

## 目的

疑似オンプレ VM（APP01 / DB01）を Spoke1 VNet に Lift & Shift で移行します。

## アーキテクチャ

```text
移行元 (rg-onprem)              移行先 (rg-spoke1)
┌──────────────────┐           ┌──────────────────┐
│ APP01 (IIS/.NET) │──Migrate─→│ vm-spoke1-web    │
│ DB01  (SQL)      │──Migrate─→│ vm-spoke1-sql    │
└──────────────────┘           └──────────────────┘
```

## 前提条件

- Phase 4 が完了していること

## 手順

### 1. Spoke1 リソースのデプロイ

```powershell
# Spoke1 用リソースをデプロイ
az deployment group create `
    --resource-group rg-spoke1 `
    --template-file infra/modules/spoke-resources/spoke1-rehost.bicep `
    --parameters adminUsername=azureadmin adminPassword='<your-password>'
```

### 2. Azure Migrate: Server Migration の設定

1. Azure Portal → Azure Migrate → `migr-project`
2. **Migration tools** → **Azure Migrate: Server Migration**
3. **Discover** → エージェントベースを選択

### 3. Mobility Service Agent のインストール

APP01 と DB01 にそれぞれ Mobility Service Agent をインストール:

```powershell
# APP01 で実行
# Azure Migrate ポータルからダウンロードした Agent を実行
.\MobilityServiceInstaller.exe /q /x:C:\Temp\MobilityService
cd C:\Temp\MobilityService
.\UnifiedAgent.exe /Role "MS" /InstallLocation "C:\Program Files (x86)\Microsoft Azure Site Recovery"
```

### 4. レプリケーションの設定

1. Azure Migrate → **Replicate**
2. ソース: APP01, DB01
3. ターゲット:
   - リソースグループ: `rg-spoke1`
   - VNet: `vnet-spoke1`
   - サブネット: `snet-web`（APP01 用）、`snet-db`（DB01 用）

### 5. テスト移行の実施

1. Azure Migrate → **Replicating machines** → 対象 VM を選択
2. **Test migration** をクリック
3. テスト VNet: `vnet-spoke1` を選択
4. テスト移行完了後、動作確認

### 6. 本番移行（カットオーバー）

1. テスト移行のクリーンアップ
2. **Migrate** をクリック
3. カットオーバー完了を確認

### 7. 動作確認

1. Bastion → `vm-spoke1-web` に RDP 接続
2. ブラウザで `http://localhost` にアクセス
3. 在庫管理アプリが正常に動作することを確認

## 確認ポイント

- [ ] vm-spoke1-web, vm-spoke1-sql が Spoke1 に作成されている
- [ ] アプリが正常動作する
- [ ] DB 接続が正常（vm-spoke1-web → vm-spoke1-sql）

## 次のステップ

→ [Phase 5b: DB PaaS 化](05b-db-paas.md) または [Phase 6: 比較・まとめ](06-compare.md)
