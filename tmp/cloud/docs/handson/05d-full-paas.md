# Phase 5d: フル PaaS 化 — Spoke4

## 目的

.NET 8 に変換したアプリを App Service にデプロイし、Azure SQL と組み合わせるフル PaaS パターンを体験します。

## アーキテクチャ

```text
移行元 (rg-onprem)                         移行先 (rg-spoke4)
┌──────────────────┐                      ┌───────────────────────────┐
│ APP01 (.NET 4.8) │──Copilot App Mod──→  │ app-spoke4 (App Service)  │
│                  │  .NET 8              │   └─ asp-spoke4 (Plan)    │
│ DB01  (SQL)      │──DMS──────────────→  │ sqldb-spoke4 (Azure SQL)  │
└──────────────────┘                      │   └─ pep-spoke4-sql (PE)  │
                                          └───────────────────────────┘
```

## 前提条件

- Phase 4 が完了していること
- GitHub Copilot ライセンス

## 手順

### 1. Spoke4 リソースのデプロイ

```powershell
az deployment group create `
    --resource-group rg-spoke4 `
    --template-file infra/modules/spoke-resources/spoke4-full-paas.bicep `
    --parameters sqlAdminLogin=sqladmin sqlAdminPassword='<sql-password>'
```

### 2. DB 移行（DMS）

Phase 5b と同様の手順で `InventoryDB` を `sqldb-spoke4` に移行。

### 3. コード変換（GitHub Copilot App Modernization）

1. GitHub Copilot App Modernization で .NET Framework 4.8 → .NET 8 に変換
   - Spoke3 で変換済みのコードを再利用可能
2. Azure SQL Database への接続文字列を更新

### 4. App Service へのデプロイ

```powershell
# ビルド
cd src/legacy-app
dotnet publish -c Release -o ./publish

# App Service にデプロイ
az webapp deploy `
    --resource-group rg-spoke4 `
    --name app-spoke4 `
    --src-path ./publish `
    --type zip
```

### 5. VNet Integration の設定

```powershell
# VNet Integration を有効化（Bicep でデプロイ済みの場合はスキップ）
az webapp vnet-integration add `
    --resource-group rg-spoke4 `
    --name app-spoke4 `
    --vnet vnet-spoke4 `
    --subnet snet-appservice
```

### 6. 接続文字列の設定

```powershell
az webapp config connection-string set `
    --resource-group rg-spoke4 `
    --name app-spoke4 `
    --connection-string-type SQLAzure `
    --settings InventoryDb="Server=sql-spoke4.database.windows.net;Database=sqldb-spoke4;Authentication=Active Directory Default;"
```

### 7. 動作確認

ブラウザで App Service の URL にアクセス:

```text
https://app-spoke4-<unique>.azurewebsites.net
```

## 確認ポイント

- [ ] App Service にアプリがデプロイされている
- [ ] VNet Integration が有効である
- [ ] Azure SQL Database に Private Endpoint 経由で接続できる
- [ ] アプリが正常動作する

## 次のステップ

→ [Phase 6: 比較・まとめ](06-compare.md)
