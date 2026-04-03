# 00. 初期環境セットアップ

この手順では、ハンズオン開始前に必要な **移行元（疑似オンプレ）** と **移行先（クラウド）** の初期環境をまとめて準備します。  
オンプレ側とクラウド側が別々の手順になっている場合でも、このドキュメントを起点にすると全体像を把握しやすくなります。

---

## 目的

- Hub & Spoke を中心とした **移行先クラウド基盤** を用意する
- `DC01` / `DB01` / `APP01` を含む **疑似オンプレ環境** を用意する
- 双方の **Azure VPN Gateway** を構成し、相互接続できる状態にする

---

## 作成される主なリソース

| 領域 | 主な構成 |
|---|---|
| クラウド側 | `rg-hub`, `rg-spoke1` ～ `rg-spoke4`, Hub VNet, Spoke VNet, Azure Firewall, Bastion, VPN Gateway |
| 疑似オンプレ側 | `rg-onprem`, `OnPrem-VNet`, `DC01`, `DB01`, `APP01`, Azure Bastion, Azure VPN Gateway |
| 接続 | クラウド側 VPN と疑似オンプレ側 VPN の接続 |

---

## 方法 A: 一度に環境を作る方法

`tmp/cloud/docs/handson/00-deploy.md` の考え方に合わせて、**環境全体を一括で作成**する方法です。  
全体の初期セットアップをまとめて実施したい場合は、この方法を使います。

### 実行例（Azure CLI / Bicep）

```powershell
az deployment sub create `
  --name hol-initial-setup `
  --location japaneast `
  --template-file tmp/cloud/infra/main.bicep `
  --parameters location='japaneast' `
               adminUsername='azureadmin' `
               adminPassword='<管理者パスワード>'
```

### この方法で一括作成されるもの

- `rg-onprem`, `rg-hub`, `rg-spoke1` ～ `rg-spoke4`
- On-Prem VNet / Hub VNet / 各 Spoke VNet
- Azure Firewall / Azure Bastion / Log Analytics / Policy / Defender
- `DC01` / `DB01` / `APP01`
- Hub 側 VPN Gateway / On-Prem 側 VPN Gateway
- VNet 間接続に必要な VPN 接続設定

> デプロイ完了まで **60〜90 分程度** かかることがあります。特に VPN Gateway の作成に時間を要します。

---

## 方法 B: 3 つのステップで構築する方法

環境を段階的に確認しながら構築したい場合は、以下の 3 ステップで進めます。

### 1) クラウド側のネットワーク接続の Hub / 各種 Spoke を作る

クラウド側の共通基盤を先に構築します。

```powershell
az deployment sub create `
  --name hol-cloud-network `
  --location japaneast `
  --template-file tmp/cloud/infra/cloud/main.bicep `
  --parameters location='japaneast' `
               deployFirewall=true `
               deployBastion=true `
               deployVpnGateway=true
```

**主な作成対象**
- `rg-hub`, `rg-spoke1` ～ `rg-spoke4`
- Hub VNet / Spoke VNet
- Azure Firewall / Bastion / Hub 側 VPN Gateway

詳細は [`04-cloud-deploy.md`](./04-cloud-deploy.md) を参照してください。

---

### 2) 疑似オンプレを作り Azure VPN を作る

次に、移行元となる疑似オンプレ環境と On-Prem 側 Azure VPN Gateway を作成します。

```powershell
az group create --name rg-onprem --location japaneast

az deployment group create `
  --name hol-onprem-base `
  --resource-group rg-onprem `
  --template-file tmp/onprem/infra/main.bicep `
  --parameters adminPassword='<管理者パスワード>' `
               vpnSharedKey='<共有キー>'
```

**主な作成対象**
- `OnPrem-VNet`
- `DC01`, `DB01`, `APP01`
- On-Prem 側 Bastion
- On-Prem 側 Azure VPN Gateway

詳細は [`01-onprem-deploy.md`](./01-onprem-deploy.md) を参照してください。

---

### 3) クラウドの Azure VPN と疑似オンプレの Azure VPN の設定を行う

Hub 側 VPN Gateway のパブリック IP を取得し、疑似オンプレ側から接続設定を追加します。

```powershell
$hubGatewayIp = az network public-ip show `
  --resource-group rg-hub `
  --name pip-vgw-hub `
  --query ipAddress -o tsv

az deployment group create `
  --name hol-onprem-vpn-connection `
  --resource-group rg-onprem `
  --template-file tmp/onprem/infra/main.bicep `
  --parameters adminPassword='<管理者パスワード>' `
               vpnSharedKey='<共有キー>' `
               remoteGatewayIp=$hubGatewayIp `
               remoteAddressPrefix='10.10.0.0/16'
```

**このステップで行うこと**
- Hub 側 VPN Gateway の接続先情報を取得
- On-Prem 側 `Local Network Gateway` を作成
- `OnPrem-to-Azure-S2S` 接続を構成

> `vpnSharedKey` は Step 2 と Step 3 で **同じ値** を使用してください。

---

## 完了後に確認すること

- `rg-hub`, `rg-spoke1` ～ `rg-spoke4`, `rg-onprem` が存在する
- `vgw-hub` と `OnPrem-VpnGw` が作成されている
- `DC01` / `DB01` / `APP01` が作成されている
- 疑似オンプレ側から Hub 側アドレス空間への接続設定が存在する

---

## 次のステップ

初期環境の準備ができたら、以下の順に進めます。

1. [`01-onprem-deploy.md`](./01-onprem-deploy.md) または [`04-cloud-deploy.md`](./04-cloud-deploy.md) で個別手順を確認
2. [`02-onprem-parts-unlimited.md`](./02-onprem-parts-unlimited.md) でアプリをセットアップ
3. [`05-cloud-explore-onprem.md`](./05-cloud-explore-onprem.md) 以降で移行ハンズオンを開始
