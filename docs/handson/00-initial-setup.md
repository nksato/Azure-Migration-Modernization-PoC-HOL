# 00. 初期環境セットアップ

ハンズオン開始前に、**移行元（疑似オンプレ）** と **移行先（クラウド）** の初期環境をまとめて準備します。

---

## 目的

- Hub & Spoke を中心とした **移行先クラウド基盤** を用意する
- `DC01` / `DB01` / `APP01` を含む **疑似オンプレ環境** を用意する
- 双方の **Azure VPN Gateway** を構成し、S2S VPN で相互接続する
- **ハイブリッド DNS** を設定し、VPN 越しの名前解決を実現する

---

## 前提条件

- Azure サブスクリプション
- リソースグループ作成権限
- Azure CLI / PowerShell を利用できる環境（[作業環境の準備](./00-prerequisites.md)）
- このリポジトリをクローン済みであること

> **リージョン制約**: クラウド側のテンプレートには、リソース作成先を **`japaneast`** と **`japanwest`** に限定する Azure Policy が含まれています。これ以外のリージョンにデプロイすると、Policy 違反でリソース作成が拒否されます。別のリージョンを使用したい場合は、`infra/cloud/modules/governance/policy.bicep` の `listOfAllowedLocations` 既定値を変更してください。

---

## 作成される主なリソース

| 領域 | 主な構成 |
|---|---|
| クラウド側 | `rg-hub`, `rg-spoke1` ～ `rg-spoke4`, Hub VNet, Spoke VNet, Azure Firewall, Bastion, DNS Private Resolver |
| 疑似オンプレ側 | `rg-onprem`, `vnet-onprem`, `DC01`, `DB01`, `APP01`, Azure Bastion |
| VPN 接続 | Hub 側 / OnPrem 側の VPN Gateway、S2S 接続 |
| DNS | DNS Forwarding Ruleset（クラウド→オンプレ）、条件付きフォワーダー（オンプレ→クラウド） |

---

## 方法 A: 一度に環境を作る方法

`infra/main.bicep` を使って環境全体をまとめて作成します。  
内部で方法 B の Step 1（疑似オンプレ）・Step 3（クラウド基盤）・Step 4（VPN 接続）を一括実行するため、方法 B と同じ構成・命名になります。

### Deploy to Azure ボタン

ブラウザからまとめてデプロイする場合は、次のボタンを利用できます。

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fmain.json)

> このボタンは `infra/main.json` を利用します。別の fork / mirror で使う場合は、リンク先 URL 内のリポジトリ パスを自身のものに置き換えてください。

### デプロイ後に必要な手動設定

Deploy to Azure ボタンまたは CLI によるデプロイが完了したら、以下の手動設定を実行してください。

1. **Parts Unlimited アプリのセットアップ** — VM 上に IIS サイトと SQL Server データベースを構成します。  
   詳細は [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md) を参照してください。

2. **ハイブリッド DNS の構成** — 双方向の DNS 転送を設定し、VPN 越しの名前解決を実現します。  
   詳細は [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md) を参照してください。

### 一括作成されるもの

- `rg-onprem`, `rg-hub`, `rg-spoke1` ～ `rg-spoke4`
- On-Prem VNet / Hub VNet / 各 Spoke VNet
- Azure Firewall / Azure Bastion / Log Analytics / Policy / Defender
- `DC01` / `DB01` / `APP01`
- Hub 側 VPN Gateway / On-Prem 側 VPN Gateway
- VNet 間接続に必要な VPN 接続設定（VNet Peering の Gateway Transit 含む）
- DNS Private Resolver（インバウンド / アウトバウンド エンドポイント）

> DNS Forwarding Ruleset と DC01 の条件付きフォワーダーは方法 A でも自動設定されません。上記「デプロイ後に必要な手動設定」の手順 2 を実行してください。

> デプロイ完了まで 60〜90 分程度かかることがあります。特に VPN Gateway の作成に時間を要します。

### 備考: Azure CLI / Bicep で実行する場合

```powershell
# 共有キーを生成して変数に格納（英数字 40 文字）
$vpnKey = -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 40 | %{[char]$_})
Write-Host "vpnSharedKey = $vpnKey"

az deployment sub create `
  --name hol-initial-setup `
  --location japaneast `
  --template-file infra/main.bicep `
  --parameters location='japaneast' `
               adminUsername='labadmin' `
               adminPassword='<管理者パスワード>' `
               domainName='lab.local' `
               vpnSharedKey="$vpnKey"
```

> `&`, `!`, `%` などの特殊文字を含む共有キーは、`az` CLI に渡す際にシェルに解釈されてエラーになることがあります。上記のように英数字のみで生成し、変数経由で渡すのが安全です。

> **Tip**: デプロイ後に共有キーを確認するには、以下のコマンドを使用してください。
>
> ```powershell
> az network vpn-connection shared-key show `
>   --resource-group rg-onprem --name cn-onprem-to-hub -o tsv
> ```

---

## 方法 B: 5 つのステップで構築する方法

一括デプロイではなく、構成を確認しながら段階的に構築したい場合は、以下の 5 ステップで進めます。

| Step | 内容 | テンプレート / スクリプト |
|------|------|------------------------|
| 1 | 疑似オンプレ環境 | `infra/onprem/main.bicep` |
| 2 | Parts Unlimited インストール | `az vm run-command` |
| 3 | クラウド基盤 (Hub & Spoke) | `infra/cloud/main.bicep` |
| 4 | VPN Gateway 配置・接続 | `infra/network/main.bicep` |
| 5 | ハイブリッド DNS | `infra/network/Setup-HybridDns.ps1` |

### Step 1: 疑似オンプレ環境を作る

移行元となる疑似オンプレ環境（VNet + VM 3 台 + Bastion）を作成します。

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fonprem%2Fmain.json)

> Portal でリージョンとパラメータを入力してデプロイします。リソースグループ `rg-onprem` は自動作成されます。

または CLI で実行:

```powershell
az deployment sub create `
  --name hol-onprem-base `
  --location japaneast `
  --template-file infra/onprem/main.bicep `
  --parameters adminPassword='<管理者パスワード>'
```

**主な作成対象**
- `vnet-onprem`（ServerSubnet + AzureBastionSubnet）
- `DC01`, `DB01`, `APP01`
- On-Prem 側 Bastion

詳細は [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) を参照してください。

---

### Step 2: Parts Unlimited アプリをセットアップする

`az vm run-command` を使って、IIS サイト構成と SQL Server のセットアップを行います。

詳細は [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md) を参照してください。

> Step 1 の VM デプロイが完了し、DC01 のドメインコントローラー昇格（`vm-onprem-ad` の再起動含む）が反映されてから実行してください。

---

### Step 3: クラウド基盤を作る

クラウド側の Hub / Spoke 基盤（Firewall, Bastion, DNS Private Resolver）を構築します。

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fcloud%2Fmain.json)

または CLI で実行:

```powershell
az deployment sub create `
  --name hol-cloud-network `
  --location japaneast `
  --template-file infra/cloud/main.bicep `
  --parameters location='japaneast' `
               deployFirewall=true `
               deployBastion=true
```

**主な作成対象**
- `rg-hub`, `rg-spoke1` ～ `rg-spoke4`
- Hub VNet / Spoke VNet
- Azure Firewall / Bastion / DNS Private Resolver

詳細は [`00d-cloud-deploy.md`](./00d-cloud-deploy.md) を参照してください。

---

### Step 4: VPN Gateway を配置し接続する

疑似オンプレ側と Hub 側の両方に VPN Gateway をデプロイし、S2S VPN を成立させます。VNet Peering もゲートウェイトランジットを有効化するよう更新されます。

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fnetwork%2Fmain.json)

または CLI で実行:

```powershell
# 共有キーを生成して変数に格納（英数字 40 文字）
$vpnKey = -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 40 | %{[char]$_})
Write-Host "vpnSharedKey = $vpnKey"

az deployment sub create `
  --name hol-vpn-setup `
  --location japaneast `
  --template-file infra/network/main.bicep `
  --parameters vpnSharedKey="$vpnKey"
```

> `&`, `!`, `%` などの特殊文字を含む共有キーは、`az` CLI に渡す際にシェルに解釈されてエラーになることがあります。上記のように英数字のみで生成し、変数経由で渡すのが安全です。

> **Tip**: デプロイ後に共有キーを確認するには、以下のコマンドを使用してください。
>
> ```powershell
> az network vpn-connection shared-key show `
>   --resource-group rg-onprem --name cn-onprem-to-hub -o tsv
> ```

**このステップで行うこと**
- On-Prem 側と Hub 側の VPN Gateway を作成
- Local Network Gateway と S2S 接続を構成
- Hub-Spoke 間の VNet Peering を Gateway Transit 有効で更新

詳細な手順は [`00e-cloud-vpn-connect.md`](./00e-cloud-vpn-connect.md) を参照してください。

---

### Step 5: ハイブリッド DNS を設定する

VPN 接続が確立したら、双方向の DNS 転送を設定します。

```powershell
.\infra\network\Setup-HybridDns.ps1
```

**このステップで行うこと**
- クラウド → オンプレ: DNS Forwarding Ruleset（`lab.local` → DC01）を作成
- オンプレ → クラウド: DC01 に `privatelink.database.windows.net` の条件付きフォワーダーを追加

詳細な手順は [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md) を参照してください。

---

## 完了確認

- `rg-hub`, `rg-spoke1` ～ `rg-spoke4`, `rg-onprem` が存在する
- `vgw-hub` と `vgw-onprem` が作成されている（方法 B の場合は Step 4 完了後）
- `DC01` / `DB01` / `APP01` が作成されている
- VPN の `connectionStatus` が `Connected` になっている
- DNS Forwarding Ruleset（`dnsrs-hub`）と DC01 の条件付きフォワーダーが設定されている

---

## 次のステップ

初期環境の準備ができたら、移行ハンズオンを開始します。

➡ [`01-cloud-explore-onprem.md`](./01-cloud-explore-onprem.md)
