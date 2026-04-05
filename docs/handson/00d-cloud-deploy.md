# 00d. クラウド基盤のデプロイ

> **Note**  
> [`00-initial-setup.md`](./00-initial-setup.md) の **Deploy to Azure** でセットアップ済みの場合、このページの手順は不要です。

**移行先となる Azure 側の Hub & Spoke 基盤**を構築します。

## 目的

- Hub VNet と 4 つの Spoke VNet を用意する
- Azure Firewall / Bastion / DNS Private Resolver / Log Analytics などの共通基盤をデプロイする
- 後続の移行パターン用の受け皿を準備する

---

## 前提条件

- Azure サブスクリプション
- クラウド環境を作成する権限
- 可能であれば移行元環境のドキュメントも確認済み
  - [`00a-onprem-deploy.md`](./00a-onprem-deploy.md)

---

## 手順

### Deploy to Azure を使う場合

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fcloud%2Fmain.json)

### Azure CLI / Bicep で実行する場合

```powershell
az deployment sub create `
  --name hol-cloud-network `
  --location japaneast `
  --template-file infra/cloud/main.bicep `
  --parameters location='japaneast' `
               deployFirewall=true `
               deployBastion=true
```

> このテンプレートは **subscription スコープ** で実行し、`rg-hub` と `rg-spoke1` ～ `rg-spoke4` をまとめて作成します。

---

## 完了確認

- `rg-hub` と各 `rg-spoke*` が存在する
- `Hub VNet` と `Spoke1-4 VNet` が作成されている
- `Azure Firewall`, `Azure Bastion` が作成されている
- DNS Private Resolver（`dnspr-hub`）が作成されている
- Private DNS Zone（`privatelink.database.windows.net`）が作成されている
- Policy / Log Analytics / Defender の土台がある

> VPN Gateway はこのステップでは作成されません。Step 4（[`00e-cloud-vpn-connect.md`](./00e-cloud-vpn-connect.md)）で別途デプロイします。

## 備考

- 参照テンプレート:
  - `infra/cloud/azuredeploy.json` — Deploy to Azure 用 ARM テンプレート
  - `infra/cloud/main.bicep` — クラウド側メイン Bicep
  - `infra/cloud/modules/network/*` — Hub / Spoke / ルーティング
  - `infra/cloud/modules/governance/*` — Log Analytics / Policy / Defender / Dashboard

## 次のステップ

クラウド基盤の作成が完了したら、次に VPN 接続を構成します。

➡ [`00e-cloud-vpn-connect.md`](./00e-cloud-vpn-connect.md)
