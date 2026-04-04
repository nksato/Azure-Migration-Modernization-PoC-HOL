# 00. 初期環境セットアップ

ハンズオン開始前に、**移行元（疑似オンプレ）** と **移行先（クラウド）** の初期環境をまとめて準備します。

---

## 目的

- Hub & Spoke を中心とした **移行先クラウド基盤** を用意する
- `DC01` / `DB01` / `APP01` を含む **疑似オンプレ環境** を用意する
- 双方の **Azure VPN Gateway** を構成し、相互接続できる状態にする

---

## 前提条件

- Azure サブスクリプション
- リソースグループ作成権限
- Azure CLI / PowerShell を利用できる環境

---

## 作成される主なリソース

| 領域 | 主な構成 |
|---|---|
| クラウド側 | `rg-hub`, `rg-spoke1` ～ `rg-spoke4`, Hub VNet, Spoke VNet, Azure Firewall, Bastion, VPN Gateway |
| 疑似オンプレ側 | `rg-onprem`, `OnPrem-VNet`, `DC01`, `DB01`, `APP01`, Azure Bastion, Azure VPN Gateway |
| 接続 | クラウド側 VPN と疑似オンプレ側 VPN の接続 |

---

## 方法 A: 一度に環境を作る方法

`infra/main.bicep` を使って環境全体をまとめて作成します。  
内部で `infra/cloud/main.bicep` と `infra/onprem/main.bicep` を呼び出すため、方法 B と同じ構成・命名になります。

### Deploy to Azure ボタン

ブラウザからまとめてデプロイする場合は、次のボタンを利用できます。

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fmain.json)

> このボタンは `infra/main.json` を利用します。別の fork / mirror で使う場合は、リンク先 URL 内のリポジトリ パスを自身のものに置き換えてください。

### デプロイ後に必要な手動設定

Deploy to Azure ボタンまたは CLI によるデプロイが完了したら、疑似オンプレ側からクラウド側の Private Endpoint を名前解決するために、DC01 に **DNS 条件付きフォワーダー**を設定します。この設定は Bicep では自動化されないため、手動で実行してください。

詳細な手順は [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md) を参照してください。

### 一括作成されるもの

- `rg-onprem`, `rg-hub`, `rg-spoke1` ～ `rg-spoke4`
- On-Prem VNet / Hub VNet / 各 Spoke VNet
- Azure Firewall / Azure Bastion / Log Analytics / Policy / Defender
- `DC01` / `DB01` / `APP01`
- Hub 側 VPN Gateway / On-Prem 側 VPN Gateway
- VNet 間接続に必要な VPN 接続設定
- DNS Private Resolver / DNS Forwarding Ruleset（クラウド → オンプレ方向の DNS 転送）

> DC01 の DNS 条件付きフォワーダー（オンプレ → クラウド方向）は方法 A でも自動設定されません。上記「デプロイ後に必要な手動設定」を実行してください。

> デプロイ完了まで 60〜90 分程度かかることがあります。特に VPN Gateway の作成に時間を要します。

### 備考: Azure CLI / Bicep で実行する場合

```powershell
az deployment sub create `
  --name hol-initial-setup `
  --location japaneast `
  --template-file infra/main.bicep `
  --parameters location='japaneast' `
               adminUsername='labadmin' `
               adminPassword='<管理者パスワード>' `
               domainName='lab.local' `
               vpnSharedKey='<共有キー>'
```

> `vpnSharedKey` には 32 文字以上のランダムな文字列を指定してください。英大文字・小文字・数字・記号を組み合わせ、サンプル値をそのまま使わないようにしてください。

---

## 方法 B: 4 つのステップで構築する方法

一括デプロイではなく、構成を確認しながら段階的に構築したい場合は、以下の 4 ステップで進めます。
まず疑似オンプレ環境を作成し、次にクラウド側の共通基盤を用意し、VPN 接続を構成したうえで、ハイブリッド DNS を設定します。

### 1) 疑似オンプレを作り Azure VPN を作る

移行元となる疑似オンプレ環境と、疑似オンプレ側の Azure VPN Gateway を作成します。

```powershell
az group create --name rg-onprem --location japaneast

az deployment group create `
  --name hol-onprem-base `
  --resource-group rg-onprem `
  --template-file infra/onprem/main.bicep `
  --parameters adminPassword='<管理者パスワード>' `
               vpnSharedKey='<共有キー>'
```

**主な作成対象**
- `OnPrem-VNet`
- `DC01`, `DB01`, `APP01`
- On-Prem 側 Bastion
- On-Prem 側 Azure VPN Gateway

詳細は [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) を参照してください。

---

### 2) クラウド側のネットワーク接続の Hub / 各種 Spoke を作る

クラウド側の Hub / Spoke 基盤と、Hub 側の Azure VPN Gateway を構築します。

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

**主な作成対象**
- `rg-hub`, `rg-spoke1` ～ `rg-spoke4`
- Hub VNet / Spoke VNet
- Azure Firewall / Bastion / Hub 側 Azure VPN Gateway

詳細は [`00d-cloud-deploy.md`](./00d-cloud-deploy.md) を参照してください。

---

### 3) クラウドの Azure VPN と疑似オンプレの Azure VPN の設定を行う

Hub 側 VPN Gateway のパブリック IP を取得し、疑似オンプレ側から接続設定を追加して VPN を成立させます。

```powershell
$hubGatewayIp = az network public-ip show `
  --resource-group rg-hub `
  --name vpngw-hub-pip1 `
  --query ipAddress -o tsv

az deployment group create `
  --name hol-onprem-vpn-connection `
  --resource-group rg-onprem `
  --template-file infra/onprem/main.bicep `
  --parameters adminPassword='<管理者パスワード>' `
               vpnSharedKey='<共有キー>' `
               remoteGatewayIp=$hubGatewayIp `
               remoteAddressPrefix='10.10.0.0/16'
```

**このステップで行うこと**
- Hub 側 VPN Gateway の接続先情報を取得
- On-Prem 側 `Local Network Gateway` を作成
- `OnPrem-to-Azure-S2S` 接続を構成

詳細な手順は [`00e-cloud-vpn-connect.md`](./00e-cloud-vpn-connect.md) を参照してください。

> `vpnSharedKey` は Step 1 で指定した値を再利用してください。

> 現在のテンプレート構成では、`infra/cloud/main.bicep` は Step 2 で Hub 側 Azure VPN Gateway を作成するまでを担当します。接続先情報（Hub 側の公開 IP）と共有キーを使った接続設定は、Step 3 で疑似オンプレ側に設定します。クラウド側での追加設定は不要です。

---

### 4) ハイブリッド DNS を設定する

VPN 接続が確立したら、疑似オンプレ側からクラウド側の Private Endpoint を名前解決できるよう、DC01 に DNS 条件付きフォワーダーを設定します。

```powershell
$dnsInboundIp = az dns-resolver inbound-endpoint show `
  --resource-group rg-hub `
  --dns-resolver-name dnspr-hub `
  --name inbound `
  --query "ipConfigurations[0].privateIpAddress" -o tsv

az vm run-command invoke `
  --resource-group rg-onprem `
  --name OnPrem-AD `
  --command-id RunPowerShellScript `
  --scripts "Add-DnsServerConditionalForwarderZone -Name 'privatelink.database.windows.net' -MasterServers '$dnsInboundIp' -ReplicationScope Forest"
```

**このステップで行うこと**
- DNS Private Resolver のインバウンド IP を取得
- DC01 に `privatelink.database.windows.net` の条件付きフォワーダーを追加

詳細な手順は [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md) を参照してください。

> クラウド側の DNS Forwarding Ruleset（`lab.local` → DC01）は Step 2 の `infra/cloud/main.bicep` デプロイ時に自動作成済みです。ここでは逆方向（オンプレ → クラウド）のみ設定します。

---

## 完了確認

- `rg-hub`, `rg-spoke1` ～ `rg-spoke4`, `rg-onprem` が存在する
- `vgw-hub` と `OnPrem-VpnGw` が作成されている
- `DC01` / `DB01` / `APP01` が作成されている
- 疑似オンプレ側から Hub 側アドレス空間への接続設定が存在する

---

## 次のステップ

初期環境の準備ができたら、以下の順に進めます。

1. [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) / [`00d-cloud-deploy.md`](./00d-cloud-deploy.md) / [`00e-cloud-vpn-connect.md`](./00e-cloud-vpn-connect.md) / [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md) で個別手順を確認
2. [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md) でアプリをセットアップ
3. [`01-cloud-explore-onprem.md`](./01-cloud-explore-onprem.md) 以降で移行ハンズオンを開始
