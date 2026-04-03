# Phase 5c: コンテナ化 — Spoke3

## 目的

.NET Framework 4.8 アプリを .NET 8 に変換し、Container Apps にデプロイするパターンを体験します。

## アーキテクチャ

```text
移行元 (rg-onprem)                         移行先 (rg-spoke3)
┌──────────────────┐                      ┌───────────────────────────┐
│ APP01 (.NET 4.8) │──Copilot App Mod──→  │ ca-spoke3 (Container App) │
│                  │  .NET 8 + Docker     │   └─ cr-spoke3 (ACR)      │
│ DB01  (SQL)      │──DMS──────────────→  │ sqldb-spoke3 (Azure SQL)  │
└──────────────────┘                      │   └─ pep-spoke3-sql (PE)  │
                                          └───────────────────────────┘
```

## 前提条件

- Phase 4 が完了していること
- GitHub Copilot ライセンス
- Docker がインストール済みのローカル環境（またはクラウドビルド）

## 手順

### 1. Spoke3 リソースのデプロイ

```powershell
az deployment group create `
    --resource-group rg-spoke3 `
    --template-file infra/modules/spoke-resources/spoke3-container.bicep `
    --parameters sqlAdminLogin=sqladmin sqlAdminPassword='<sql-password>'
```

### 2. DB 移行（DMS）

Phase 5b と同様の手順で `InventoryDB` を `sqldb-spoke3` に移行。

### 3. コード変換（GitHub Copilot App Modernization）

1. GitHub Copilot App Modernization で .NET Framework 4.8 → .NET 8 に変換
2. 変換結果のレビュー・修正
3. Azure SQL Database への接続文字列を更新

### 4. Dockerfile の作成

```dockerfile
# マルチステージビルド
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY . .
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish .
EXPOSE 8080
ENTRYPOINT ["dotnet", "InventoryApp.dll"]
```

### 5. コンテナイメージのビルドと ACR へのプッシュ

```powershell
# ACR にログイン
az acr login --name crspoke3

# イメージのビルドとプッシュ
az acr build --registry crspoke3 --image inventory-app:v1 ./src/legacy-app/
```

### 6. Container Apps へのデプロイ

```powershell
az containerapp create `
    --name ca-spoke3 `
    --resource-group rg-spoke3 `
    --environment cae-spoke3 `
    --image crspoke3.azurecr.io/inventory-app:v1 `
    --target-port 8080 `
    --ingress external `
    --env-vars "ConnectionStrings__InventoryDb=Server=sql-spoke3.database.windows.net;Database=sqldb-spoke3;Authentication=Active Directory Default;"
```

### 7. 動作確認

Container Apps のパブリック Ingress URL にブラウザでアクセス:

```text
https://ca-spoke3.<region>.azurecontainerapps.io
```

## 確認ポイント

- [ ] .NET 8 への変換が完了し、ビルドが成功する
- [ ] コンテナイメージが ACR にプッシュされている
- [ ] Container Apps でアプリが正常動作する
- [ ] Azure SQL Database に Private Endpoint 経由で接続できる

## 次のステップ

→ [Phase 5d: フル PaaS](05d-full-paas.md) または [Phase 6: 比較・まとめ](06-compare.md)
