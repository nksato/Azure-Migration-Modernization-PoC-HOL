# トラブルシューティング: Firewall / DNS Resolver のデプロイ失敗

Cloud 環境 (`rg-hub`) のデプロイで Azure Firewall や DNS Private Resolver が失敗した場合のリカバリ手順です。

## 症状

- Azure Portal のデプロイ詳細で以下のリソースが `失敗` と表示される:
  - `firewall-*` — Azure Firewall
  - `dnsResolver-*` — DNS Private Resolver
  - `dnsResolver-inbound-*` / `dnsResolver-outbound-*` — DNS Resolver エンドポイント
- リソースグループ `rg-hub` にリソース自体は存在するが、設定が不完全

## エラーメッセージ

### Azure Firewall

```
InternalServerError: エラーが発生しました。
```

Azure 側の一時的なサーバーエラーです。テンプレートやパラメータの問題ではありません。

### DNS Resolver Inbound / Outbound

```
InternalServerError: 操作が最大処理数を超えました。
circuitBreaker=[state=Open, processedCount=6, maxProcessedCount=5]
```

Azure 側のスロットリング (サーキットブレーカー) が発動しています。短時間に複数の操作が集中したことが原因です。

## 原因

どちらも **Azure 側の一過性エラー** です。リージョンの負荷やタイミングにより発生します。テンプレートの修正は不要で、再デプロイで解決します。

---

## 前提条件

- Azure CLI がインストール済み
- デプロイ時に使用したサブスクリプションにログイン済み

---

## 手順

### 方法 1: Azure Portal から再デプロイ（簡単）

1. Azure Portal で `rg-hub` のリソースグループを開く
2. 左メニューの **[デプロイ]** を選択
3. 最新のデプロイをクリック
4. **[再デプロイ]** ボタンをクリック
5. パラメータを確認してそのまま **[確認と作成]** → **[作成]**

> 既存のリソース (VNet, VPN Gateway, Bastion 等) はべき等のため、再デプロイしても影響ありません。

---

### 方法 2: Azure CLI で再デプロイ

```powershell
az deployment sub create `
  --location japaneast `
  --template-file infra/cloud/main.json `
  --parameters infra/cloud/main.bicepparam
```

> テンプレートが更新されている場合は、先に JSON をリビルドしてください:
>
> ```powershell
> az bicep build --file infra/cloud/main.bicep --outfile infra/cloud/main.json
> ```

---

### 方法 3: 失敗リソースを削除してから再デプロイ

再デプロイでも同じエラーが繰り返される場合は、`Failed` 状態のリソースを削除してから再実行します。

#### Firewall が失敗した場合

```powershell
# 失敗した Firewall と関連 PIP を削除
az network firewall delete -g rg-hub -n afw-hub --yes
az network public-ip delete -g rg-hub -n pip-afw-hub 2>$null
az network public-ip delete -g rg-hub -n pip-afw-hub-mgmt 2>$null

# 再デプロイ
az deployment sub create `
  --location japaneast `
  --template-file infra/cloud/main.bicep `
  --parameters deployFirewall=true deployBastion=true
```

#### DNS Resolver が失敗した場合

```powershell
# 失敗した DNS Resolver を削除（エンドポイントも自動削除される）
az dns-resolver delete -g rg-hub -n dnspr-hub --yes

# 再デプロイ
az deployment sub create `
  --location japaneast `
  --template-file infra/cloud/main.bicep `
  --parameters deployFirewall=true deployBastion=true
```

---

### 確認: Firewall のプロビジョニング状態

```powershell
az network firewall show -g rg-hub -n afw-hub --query provisioningState -o tsv
```

**期待結果:** `Succeeded`

### 確認: DNS Resolver のプロビジョニング状態

```powershell
# DNS Resolver 本体
az dns-resolver show -g rg-hub -n dnspr-hub --query provisioningState -o tsv

# Inbound Endpoint
az dns-resolver inbound-endpoint list -g rg-hub --dns-resolver-name dnspr-hub `
  --query "[].{name:name, state:provisioningState, ip:ipConfigurations[0].privateIpAddress}" -o table

# Outbound Endpoint
az dns-resolver outbound-endpoint list -g rg-hub --dns-resolver-name dnspr-hub `
  --query "[].{name:name, state:provisioningState}" -o table
```

**期待結果:** すべて `Succeeded`

---

## デプロイエラーの詳細確認 (参考)

失敗原因を調べたい場合は、以下のコマンドでエラー詳細を取得できます。

```powershell
# 失敗したデプロイの一覧
az deployment group list -g rg-hub `
  --query "[?properties.provisioningState=='Failed'].{name:name, time:properties.timestamp}" -o table

# 特定のデプロイの操作レベルエラー (デプロイ名を置き換え)
az deployment operation group list -g rg-hub -n "<デプロイ名>" `
  --query "[?properties.provisioningState=='Failed'].properties.statusMessage" -o json
```
