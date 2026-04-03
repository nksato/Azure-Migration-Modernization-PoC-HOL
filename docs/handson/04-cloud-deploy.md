# 04. クラウド基盤のデプロイ

このフェーズでは、**移行先となる Azure 側の Hub & Spoke 基盤**を構築します。

## 目的

- Hub VNet と 4 つの Spoke VNet を用意する
- Azure Firewall / VPN Gateway / Bastion / Log Analytics などの共通基盤をデプロイする
- 後続の移行パターン用の受け皿を準備する

---

## 前提

- Azure サブスクリプション
- クラウド環境を作成する権限
- 可能であれば移行元環境のドキュメントも確認済み
  - [`01-onprem-deploy.md`](./01-onprem-deploy.md)

---

## 参照テンプレート

| ファイル | 用途 |
|---|---|
| `tmp/cloud/infra/cloud/azuredeploy.json` | Deploy to Azure 用 ARM テンプレート |
| `tmp/cloud/infra/cloud/main.bicep` | クラウド側メイン Bicep |
| `tmp/cloud/infra/modules/network/*` | Hub / Spoke / VPN / ルーティング |
| `tmp/cloud/infra/modules/governance/*` | Log Analytics / Policy / Defender |

---

## 手順例

### Deploy to Azure を使う場合

`tmp/cloud/README.md` に記載のデプロイ導線を利用します。

### Azure CLI / Bicep で実行する場合

```powershell
az group create --name rg-hub --location japaneast

az deployment group create `
  --resource-group rg-hub `
  --template-file tmp/cloud/infra/cloud/main.bicep
```

> 実際には Hub / Spoke ごとに複数のリソースグループを作る構成を想定しています。

---

## 完了後に確認すること

- `rg-hub` と各 `rg-spoke*` が存在する
- `Hub VNet` と `Spoke1-4 VNet` が作成されている
- `Azure Firewall`, `VPN Gateway`, `Azure Bastion` が作成されている
- Policy / Log Analytics / Defender の土台がある

## 次のステップ

➡ [`05-cloud-explore-onprem.md`](./05-cloud-explore-onprem.md)
