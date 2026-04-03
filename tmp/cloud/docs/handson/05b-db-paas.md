# Phase 5b: DB PaaS 化 — Spoke2

## 目的

DB のみ Azure SQL Database に PaaS 化し、Web は IIS VM のまま運用するパターンを体験します。

## アーキテクチャ

```text
移行元 (rg-onprem)              移行先 (rg-spoke2)
┌──────────────────┐           ┌──────────────────────────┐
│ APP01 (IIS/.NET) │──Deploy──→│ vm-spoke2-web (IIS)      │
│ DB01  (SQL)      │──DMS────→│ sqldb-spoke2 (Azure SQL)  │
└──────────────────┘           │   └─ pep-spoke2-sql (PE) │
                               └──────────────────────────┘
```

## 前提条件

- Phase 4 が完了していること
- GitHub Copilot ライセンス

## 手順

### 1. Spoke2 リソースのデプロイ

```powershell
az deployment group create `
    --resource-group rg-spoke2 `
    --template-file infra/modules/spoke-resources/spoke2-db-paas.bicep `
    --parameters adminUsername=azureadmin adminPassword='<your-password>' `
                 sqlAdminLogin=sqladmin sqlAdminPassword='<sql-password>'
```

### 2. DB 移行（DMS）

1. Azure Portal → **Database Migration Service** を作成
2. ソース: DB01 上の SQL Server 2019 (`InventoryDB`)
3. ターゲット: `sqldb-spoke2`（Azure SQL Database）
4. オフライン移行を選択
5. スキーマ + データの移行を実行

### 3. アプリのコード変更（GitHub Copilot App Modernization）

GitHub Copilot App Modernization で以下を変更（フレームワークは .NET Framework 4.8 のまま）:

1. **接続文字列の変更**
   ```xml
   <!-- 変更前: Web.config -->
   <connectionStrings>
     <add name="InventoryDb"
          connectionString="Server=DB01;Database=InventoryDB;Integrated Security=true;"
          providerName="System.Data.SqlClient" />
   </connectionStrings>

   <!-- 変更後 -->
   <connectionStrings>
     <add name="InventoryDb"
          connectionString="Server=sql-spoke2.database.windows.net;Database=sqldb-spoke2;Authentication=Active Directory Default;"
          providerName="System.Data.SqlClient" />
   </connectionStrings>
   ```

2. **認証方式の変更**: Windows 認証 → Microsoft Entra 認証 or SQL 認証

### 4. 変更後アプリを VM にデプロイ

1. 変更後のアプリをビルド
2. vm-spoke2-web の IIS にデプロイ

### 5. 動作確認

1. Bastion → `vm-spoke2-web` に RDP 接続
2. ブラウザで `http://localhost` にアクセス
3. 在庫管理アプリが Azure SQL Database に接続して動作することを確認

## 確認ポイント

- [ ] Azure SQL Database にデータが移行されている
- [ ] Private Endpoint 経由で DB に接続できる
- [ ] アプリが正常動作する

## 次のステップ

→ [Phase 5c: コンテナ化](05c-containerize.md) または [Phase 6: 比較・まとめ](06-compare.md)
