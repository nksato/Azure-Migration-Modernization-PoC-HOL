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

**一括セットアップ用エントリポイント** を使って、環境全体をまとめて作成する方法です。  
現在の正式な配置は `infra/main.bicep` で、内部で `infra/cloud/main.bicep` と `infra/onprem/main.bicep` を呼び出すため、**方法 B と同じ構成・命名** で初期セットアップを実施できます。

### 実行例（Azure CLI / Bicep）

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

> `infra/main.bicep` は一括セットアップ用、`infra/cloud/main.bicep` はクラウド側のみを構築するテンプレートです。用途に応じて使い分けてください。

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

一括デプロイではなく、構成を確認しながら段階的に構築したい場合は、以下の 3 ステップで進めます。
まず疑似オンプレ環境を作成し、次にクラウド側の共通基盤を用意し、最後に両者の VPN 接続を構成します。

### 1) 疑似オンプレを作り Azure VPN を作る

まず、移行元となる疑似オンプレ環境と、疑似オンプレ側の Azure VPN Gateway を作成します。
このステップで、後続の接続試験や移行評価の対象となる `DC01` / `DB01` / `APP01` を準備します。

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

次に、クラウド側の Hub / Spoke 基盤と、Hub 側の Azure VPN Gateway を構築します。
この時点では、クラウド側に「接続の受け口」を用意するところまでを行います。

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

最後に、Hub 側 VPN Gateway のパブリック IP を取得し、疑似オンプレ側から接続設定を追加して VPN を成立させます。

```powershell
$hubGatewayIp = az network public-ip show `
  --resource-group rg-hub `
  --name pip-vgw-hub `
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

> `vpnSharedKey` は **Step 1 で指定した値を、Step 3 でもそのまま再利用**してください。

> 現在のテンプレート構成では、クラウド側の `infra/cloud/main.bicep` は **Step 2 で Hub 側 Azure VPN Gateway を作成するまで**を担当します。実際の接続先情報（Hub 側の公開 IP）と共有キーを使った接続設定は、**Step 3 で疑似オンプレ側に設定**する想定です。

> そのため、この手順では **クラウド側で追加の共有キー入力や接続元 IP の手動設定は不要**です。Step 3 で `remoteGatewayIp` と `vpnSharedKey` を指定して接続を完了させます。

---

## 完了後に確認すること

- `rg-hub`, `rg-spoke1` ～ `rg-spoke4`, `rg-onprem` が存在する
- `vgw-hub` と `OnPrem-VpnGw` が作成されている
- `DC01` / `DB01` / `APP01` が作成されている
- 疑似オンプレ側から Hub 側アドレス空間への接続設定が存在する

---

## 次のステップ

初期環境の準備ができたら、以下の順に進めます。

1. [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) / [`00d-cloud-deploy.md`](./00d-cloud-deploy.md) / [`00e-cloud-vpn-connect.md`](./00e-cloud-vpn-connect.md) で個別手順を確認
2. [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md) でアプリをセットアップ
3. [`01-cloud-explore-onprem.md`](./01-cloud-explore-onprem.md) 以降で移行ハンズオンを開始
