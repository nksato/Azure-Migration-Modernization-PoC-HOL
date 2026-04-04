# 00d. クラウド基盤のデプロイ

**移行先となる Azure 側の Hub & Spoke 基盤**を構築します。

## 目的

- Hub VNet と 4 つの Spoke VNet を用意する
- Azure Firewall / VPN Gateway / Bastion / Log Analytics などの共通基盤をデプロイする
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

リポジトリの `README.md` や `docs/README.md` から、ハンズオン向けのデプロイ導線を利用します。

### Azure CLI / Bicep で実行する場合

```powershell
az deployment sub create `
  --name hol-cloud-network `
  --location japaneast `
  --template-file infra/cloud/main.bicep `
  --parameters location='japaneast' `
               deployFirewall=true `
               deployBastion=true `
               deployVpnGateway=true
```

> このテンプレートは **subscription スコープ** で実行し、`rg-hub` と `rg-spoke1` ～ `rg-spoke4` をまとめて作成します。

---

## 完了確認

- `rg-hub` と各 `rg-spoke*` が存在する
- `Hub VNet` と `Spoke1-4 VNet` が作成されている
- `Azure Firewall`, `VPN Gateway`, `Azure Bastion` が作成されている
- DNS Private Resolver（`dnspr-hub`）と DNS Forwarding Ruleset（`dnsrs-hub`）が作成されている
- Private DNS Zone（`privatelink.database.windows.net`）が作成されている
- Policy / Log Analytics / Defender の土台がある

## 備考

- 参照テンプレート:
  - `infra/cloud/azuredeploy.json` — Deploy to Azure 用 ARM テンプレート
  - `infra/cloud/main.bicep` — クラウド側メイン Bicep
  - `infra/cloud/modules/network/*` — Hub / Spoke / VPN / ルーティング
  - `infra/cloud/modules/governance/*` — Log Analytics / Policy / Defender / Dashboard
- DNS Forwarding Ruleset は、クラウド側から疑似オンプレ側の `lab.local` ドメインを名前解決するための転送ルールです。逆方向（疑似オンプレ → クラウド）の DNS 設定は [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md) で行います。

## 次のステップ

クラウド基盤の作成が完了したら、次に VPN 接続を構成します。

➡ [`00e-cloud-vpn-connect.md`](./00e-cloud-vpn-connect.md)
