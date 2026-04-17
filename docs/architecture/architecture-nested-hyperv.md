# Nested Hyper-V 疑似オンプレ環境 — 設計と構築手順

Azure 上に Nested Hyper-V を利用した疑似オンプレミス環境を構築し、S2S VPN + Hybrid DNS で Hub-Spoke ネットワークに接続する。Azure Migrate 等による移行検証の基盤として使用する。

---

## 1. アーキテクチャ概要

### 1.1 疑似オンプレ環境（rg-onprem-nested）

```
vnet-onprem-nested (10.1.0.0/16)
├── AzureBastionSubnet (10.1.0.0/26)
│   └── Azure Bastion (Standard) ... 管理アクセス用
├── GatewaySubnet (10.1.255.0/27)
│   └── VPN Gateway (vgw-onprem) ... S2S VPN 用
└── snet-onprem-nested (10.1.1.0/24) ... NAT Gateway で送信インターネット
    ├── NAT Gateway (ng-onprem-nested) ... 送信インターネットアクセス
    └── Hyper-V Host VM (Windows Server 2022, Standard_E4s_v5)
        ├── F: ドライブ (256 GB データディスク)
        ├── InternalNAT Switch (192.168.100.0/24)
        ├── vm-ad01  (WS2022) ... AD DS     192.168.100.10
        ├── vm-app01 (WS2019) ... App       192.168.100.11
        └── vm-sql01 (WS2019) ... SQL       192.168.100.12
```

### 1.2 VPN 接続（onprem-nested ↔ Hub）

```
rg-onprem-nested                    rg-hub
┌──────────────────────┐            ┌──────────────────────┐
│ vnet-onprem-nested   │            │ vnet-hub             │
│ 10.1.0.0/16          │            │ 10.10.0.0/16         │
│                      │            │                      │
│ ┌──────────────────┐ │    S2S     │ ┌──────────────────┐ │
│ │ GatewaySubnet    │◄├────────────┤►│ GatewaySubnet    │ │
│ │ 10.1.255.0/27    │ │   IPsec    │ │ 10.10.255.0/27   │ │
│ └──────────────────┘ │            │ └──────────────────┘ │
│                      │            │                      │
│ lgw-hub              │            │ lgw-onprem-nested    │
│ (Hub の PIP 参照)     │            │ (OnPrem の PIP 参照)  │
└──────────────────────┘            └──────────────────────┘
                                           │
                                    Hub-Spoke Peering
                                    (Gateway Transit)
                                           │
                          ┌────────────────┼────────────────┐
                          ▼                ▼                ▼
                     rg-spoke1        rg-spoke2 ...    rg-spoke4
                    10.20.0.0/16     10.21.0.0/16     10.23.0.0/16
```

### 1.3 DNS フロー

```
Cloud → contoso.local:
  Spoke VM → Hub DNS Resolver (Outbound) → Forwarding Ruleset (frs-hub)
    → VPN → Host (vm-onprem-nested-hv01:53) → vm-ad01 (192.168.100.10)

On-prem → privatelink.*:
  vm-app01/vm-sql01 → vm-ad01 (条件付きフォワーダー)
    → VPN → Hub DNS Resolver (Inbound) → Private DNS Zone

On-prem → azure.internal (オプション):
  vm-ad01 → VPN → Hub DNS Resolver (Inbound) → Private DNS Zone (azure.internal)
```

### 1.4 ネットワーク制御

| 制御 | 内容 |
|------|------|
| NAT Gateway | `ng-onprem-nested` で送信インターネットアクセスを提供 |
| NSG (VM) | `nsg-onprem-nested` — `AllowVNetInbound` + `DenyInternetInbound` で受信を制限 |
| NSG (Bastion) | `nsg-bas-onprem-nested` — Standard SKU では Bastion サブネットに NSG が必須 |
| Public IP | VM には付与しない（`defaultOutboundAccess: false`） |

### 1.5 Bastion SKU

Bastion は **Standard** SKU を使用する。Nested Hyper-V 内のゲスト VM へ Bastion 経由で PowerShell Direct を実行する場合、Standard 以上の SKU が必要（Basic ではネイティブクライアント接続が非対応）。Standard SKU では Bastion サブネットに NSG の明示的な設定が必須となるため、`nsg-bas-onprem-nested` を構成している。

### 1.6 ゲスト VM スペック

| VM 名 | OS | 役割 | vCPU | メモリ | IP |
|--------|------|------|------|--------|-----|
| vm-ad01 | WS 2022 | Active Directory | 2 | 4 GB | 192.168.100.10 |
| vm-app01 | WS 2019 | Application | 2 | 4 GB | 192.168.100.11 |
| vm-sql01 | WS 2019 | SQL Server | 2 | 8 GB | 192.168.100.12 |

### 1.7 Hyper-V ホスト VM サイズの目安

| サイズ | vCPU | メモリ | 推奨用途 |
|--------|------|--------|----------|
| Standard_E4s_v5 | 4 | 32 GB | ネスト VM 1-2 台 |
| Standard_E8s_v5 | 8 | 64 GB | ネスト VM 3-4 台 |
| Standard_E16s_v5 | 16 | 128 GB | ネスト VM 5 台以上 |

---

## 2. 前提条件

- Azure CLI (`az`) がインストール済み
- azcopy がインストール済み（VHD アップロードに使用）
- Azure サブスクリプションへのログイン済み (`az login`)
- Contributor 以上のロール
- Windows Server 2022 / 2019 の固定サイズ VHD ファイル
- （VPN 接続する場合）クラウド環境がデプロイ済み（`infra/cloud/main.bicep`）
  - `rg-hub` に `vnet-hub`（GatewaySubnet 含む）
  - `rg-spoke1` 〜 `rg-spoke4` に各 VNet

## 3. Windows Server VHD の入手

Nested Hyper-V のゲスト VM は Azure VM ではないため、Azure Marketplace から OS イメージを直接デプロイすることはできない。ゲスト VM 用の Windows Server VHD/ISO を別途入手し、ライセンス条件に従って使用する必要がある。

### 入手方法

| 方法 | 費用 | 有効期間 | 入手形式 | 備考 |
|------|------|---------|---------|------|
| **Evaluation Center (体験版)** | 無料 | 180 日 | ISO / VHD | 評価目的のみ。VHD 形式なら変換不要 |
| **Visual Studio サブスクリプション** | サブスク費用 | サブスク有効中 | ISO | 開発/テスト目的。ISO → VHD 変換が必要 |

- **Evaluation Center**: https://www.microsoft.com/ja-jp/evalcenter/
- **Visual Studio サブスクリプション**: https://my.visualstudio.com/Downloads

> **ISO → VHD 変換**: ISO はインストールメディアのため、そのままでは使用できない。固定サイズ VHD への変換が必要。
> - [Convert-WindowsImage を使用した VHD の作成](https://learn.microsoft.com/ja-jp/microsoft-desktop-optimization-pack/app-v/appv-auto-provision-a-vm)
> - [DISM イメージ管理コマンド](https://learn.microsoft.com/ja-jp/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14?view=windows-11)

> **注意**: Azure VM のライセンスはゲスト VM をカバーしない。Nested Hyper-V 上で Windows Server を実行する場合、上記いずれかの方法で適切なライセンスを確保すること。

---

## 4. 疑似オンプレ環境のデプロイ

テンプレート: `infra/nested/onprem/`

### 4.1 リソースグループ作成

```bash
az group create --name rg-onprem-nested --location japaneast
```

### 4.2 Bicep デプロイ実行

```powershell
az deployment group create `
  --resource-group rg-onprem-nested `
  --template-file main.bicep `
  --parameters main.bicepparam `
  --parameters adminPassword='<YOUR_PASSWORD>'
```

> `adminUsername` は `main.bicepparam` で変更可能。
>
> **注意**: ここで設定する `adminPassword` は **Hyper-V ホスト VM**（Bastion RDP 接続用）のパスワード。ゲスト VM（vm-ad01 等）のパスワードとは別。
> - **一括セットアップ**: ゲスト VM のパスワードは `Setup-NestedEnvironment.ps1` が `unattend.xml` 経由で自動設定する（`P@ssW0rd1234!`）。
> - **ステップ実行**: ステップ 4.7 の OOBE 時に手動で `P@ssW0rd1234!` を設定する。

### 4.3 VHD イメージのアップロード

アップロード前に VHD の形式を確認する（**管理者権限の PowerShell** で実行。Hyper-V PowerShell モジュールが必要）:

```powershell
Get-VHD -Path "C:\path\to\ws2022.vhd" | Select-Object VhdFormat, VhdType, Size, FileSize
Get-VHD -Path "C:\path\to\ws2019.vhd" | Select-Object VhdFormat, VhdType, Size, FileSize
```

| VhdFormat | VhdType | 対応 |
|-----------|---------|------|
| VHD | Fixed | そのまま使用可 |
| VHD | Dynamic | `Convert-VHD` で Fixed に変換 |
| VHDX | Fixed / Dynamic | `Convert-VHD` で Fixed VHD に変換 |

> 動的 VHD や VHDX 形式の場合、事前に変換が必要（**管理者権限の PowerShell** で実行。Hyper-V 機能の有効化が必要）:
> ```powershell
> Convert-VHD -Path .\dynamic.vhdx -DestinationPath .\fixed.vhd -VHDType Fixed
> ```

**ローカル PC** から VHD を Managed Disk としてアップロードし、Hyper-V ホストにアタッチする:

```powershell
.\scripts\Upload-VHDs.ps1 `
    -VhdPathWs2022 "C:\path\to\ws2022.vhd" `
    -VhdPathWs2019 "C:\path\to\ws2019.vhd"
```

### 4.4 Hyper-V ホスト VM への接続

デプロイ完了後、VM は自動的に再起動して Hyper-V が有効化される。再起動完了後、Bastion 経由で接続する。

```powershell
az network bastion rdp `
  --name bas-onprem-nested `
  --resource-group rg-onprem-nested `
  --target-resource-id <VM_RESOURCE_ID>
```

> `<VM_RESOURCE_ID>` の例:
> ```
> /subscriptions/<サブスクリプションID>/resourceGroups/rg-onprem-nested/providers/Microsoft.Compute/virtualMachines/vm-onprem-nested-hv01
> ```

または Azure Portal から Bastion 経由で RDP 接続する。

### 4.5 ネスト VM 用ネットワーク設定

Bastion RDP または `az vm run-command` のいずれかで実行可能。

**Bastion RDP で Hyper-V ホスト VM 上で実行する場合:**

```powershell
.\scripts\host\Setup-NestedNetwork.ps1
```

**ローカル PC から `az vm run-command` で実行する場合:**

```powershell
# ラッパースクリプト
.\01-Setup-Network.ps1

# az vm run-command を直接実行する場合
az vm run-command invoke `
    --resource-group rg-onprem-nested `
    --name vm-onprem-nested-hv01 `
    --command-id RunPowerShellScript `
    --scripts @scripts/host/Setup-NestedNetwork.ps1
```

これにより以下が構成される:
- 内部仮想スイッチ `InternalNAT`
- NAT (192.168.100.0/24)
- DHCP スコープ (192.168.100.100 - 200)

### 4.6 ネスト VM の作成

VHDX 変換に数分かかるため、`az vm run-command` の場合はタイムアウトに注意。

**Bastion RDP で Hyper-V ホスト VM 上で実行する場合:**

```powershell
.\scripts\host\Create-NestedVMs.ps1
```

**ローカル PC から `az vm run-command` で実行する場合:**

```powershell
# ラッパースクリプト（非同期）
.\02-Create-VMs.ps1

# az vm run-command を直接実行する場合（非同期・タイムアウト 1 時間）
az vm run-command create `
    --resource-group rg-onprem-nested `
    --vm-name vm-onprem-nested-hv01 `
    --name CreateNestedVMs `
    --script @scripts/host/Create-NestedVMs.ps1 `
    --async-execution true `
    --timeout-in-seconds 3600 `
    --no-wait
```

### 4.7 ゲスト OS セットアップ（ステップ実行）

> **ヒント**: 一括セットアップ（`Setup-NestedEnvironment.ps1`）を使用する場合、このステップ 4.7 は不要。一括セットアップでは OOBE が `unattend.xml` で自動化される。「[備考: 一括セットアップ](#備考-一括セットアップhyper-v-ホストから実行)」を参照。

Bastion RDP でホスト VM に接続し、各 VM を起動して OOBE（初期セットアップ）を完了した後、以下のスクリプトを順に実行する。

> **重要**: OOBE で設定する Administrator パスワードは `P@ssW0rd1234!` (本 HOL 内スクリプト内にハードコードしている値)にすること。後続のスクリプトがこのパスワードで PowerShell Direct 接続を行う。

**(1) VM 起動**

**Bastion RDP で Hyper-V ホスト VM 上で実行する場合:**

```powershell
Start-VM vm-ad01, vm-app01, vm-sql01
```

**ローカル PC から `az vm run-command` で実行する場合:**

```powershell
.\03-Start-VMs.ps1
```

**(2) OOBE（Bastion RDP でホスト VM 上で実行）:**

Hyper-V マネージャーで各 VM に接続し OOBE（初期セットアップ）を完了する。

**(3) 固定 IP 設定 → (4) AD DS インストール → (5) ドメイン参加** を順に実行する。

**Bastion RDP で Hyper-V ホスト VM 上で実行する場合:**

```powershell
# (3) 固定 IP 設定
.\scripts\host\Configure-StaticIPs.ps1

# (4) AD DS インストール・DC 昇格 (vm-ad01 が自動再起動)
.\scripts\host\Install-ADDS.ps1

# (5) ドメイン参加 (vm-app01, vm-sql01)
.\scripts\host\Join-Domain.ps1
```

**ローカル PC から `az vm run-command` で実行する場合:**

```powershell
# (3) 固定 IP 設定
.\04-Configure-IPs.ps1

# (4) AD DS インストール・DC 昇格 (vm-ad01 が自動再起動)
.\05-Install-ADDS.ps1

# (5) ドメイン参加 (vm-app01, vm-sql01)
.\06-Join-Domain.ps1
```

#### パスワード埋め込みスクリプトについて

以下のスクリプトにはゲスト VM の認証用パスワード (`P@ssW0rd1234!`) がハードコードされている。

| スクリプト | パスワードの用途 |
|-----------|----------------|
| `Configure-StaticIPs.ps1` | ローカル Administrator でゲスト VM に PowerShell Direct 接続 |
| `Install-ADDS.ps1` | 同上 + DSRM (ディレクトリサービス復元モード) パスワード |
| `Join-Domain.ps1` | ローカル Administrator + ドメイン Administrator で接続 |
| `Setup-HybridDns.ps1` | ドメイン Administrator で DC に DNS 設定（パラメータ既定値） |
| `Verify-OnpremSetup.ps1` | 各ゲスト VM への接続検証 |

**理由**: これらのスクリプトは `az vm run-command` で非対話的に実行される場合があり、その中で `Invoke-Command -VMName`（PowerShell Direct）を使ってゲスト VM を操作する。非対話実行では資格情報のプロンプトを表示できないため、スクリプト内に埋め込んでいる。

> ⚠️ **本番環境では使用しないこと。** PoC / ハンズオン用の構成。本番では Azure Key Vault 等からの取得を推奨。

### 4.8 アップロードディスクのクリーンアップ

ネスト VM 作成後、不要になったアップロード用 Managed Disk を削除してコスト削減:

```bash
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2022
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2019
az disk delete -g rg-onprem-nested -n disk-upload-ws2022 --yes
az disk delete -g rg-onprem-nested -n disk-upload-ws2019 --yes
```

---

## 5. VPN 接続（onprem-nested ↔ Hub）

テンプレート: `infra/nested/network/`

### 5.1 使用パターン

#### A) Standalone モード（デフォルト）

onprem-nested のみを Hub に接続する場合。Hub VPN Gateway を新規作成する。

```
createHubVpnGateway = true  (デフォルト)
```

#### B) Dual モード

`infra/network/` で既に Hub VPN Gateway を作成済みの場合。既存の Hub GW を共有し、onprem と onprem-nested の両方を Hub に接続する。

```powershell
# main.bicepparam で以下のコメントを外す:
# param createHubVpnGateway = false
```

> **注意**: Dual モードでは Hub GW の LGW が 2 つ（`lgw-onprem` + `lgw-onprem-nested`）になる。

### 5.2 VPN デプロイ

```powershell
cd infra/nested/network

# 共有キーを設定（任意の文字列）
$env:VPN_SHARED_KEY = '<your-shared-key>'

# デプロイ実行（所要時間: 30〜45 分）
az deployment sub create `
    -l japaneast `
    -f main.bicep `
    -p main.bicepparam
```

デプロイされるリソース:

| フェーズ | リソース | リソースグループ | 説明 |
|---------|---------|----------------|------|
| 1 | `vgw-onprem` + PIP | rg-onprem-nested | オンプレ側 VPN Gateway |
| 2 | `vpngw-hub` + PIP | rg-hub | Hub 側 VPN Gateway（Standalone のみ） |
| 3a | LGW (`lgw-hub`, `lgw-onprem-nested`) | 各 RG | Local Network Gateway（相手側 PIP 参照） |
| 3b | Connection (`cn-*`) | 各 RG | S2S VPN 接続（双方向） |
| 4 | Hub-Spoke Peering 更新 | rg-hub | Gateway Transit 有効化（Standalone のみ） |

### 5.3 VPN 接続の確認

```powershell
.\scripts\Verify-VpnConnection.ps1
```

Spoke からの到達性も検証する場合:

```powershell
.\scripts\Verify-VpnConnection.ps1 -TestSpokeReachability
```

---

## 6. Hybrid DNS セットアップ

テンプレート: `infra/nested/network/`

VPN 接続が確立された後、Hybrid DNS を構成する。

### 6.1 DNS セットアップ実行

```powershell
.\Setup-HybridDns.ps1
```

スクリプトの実行ステップ:

| ステップ | 実行先 | 内容 |
|---------|--------|------|
| [1] | Cloud | DNS Forwarding Ruleset (`frs-hub`) 作成 |
| [2] | Cloud | Forwarding Rule 追加（`contoso.local` → Host IP） |
| [3] | Cloud | Ruleset を Hub VNet にリンク |
| [4] | On-prem | Host に DNS Server ロールをインストール (run-command) |
| [5] | On-prem | Host DNS クライアント: `127.0.0.1` + Azure DNS (run-command) |
| [6] | On-prem | Host に条件付きフォワーダー（`contoso.local` → vm-ad01）(run-command) |
| [7] | On-prem | vm-ad01 に条件付きフォワーダー（`privatelink.*` → Hub DNS Resolver）(run-command) |
| [8] | 検証 | 名前解決テスト（contoso.local, privatelink.*） |

### 6.2 オプション: Spoke VNet への Ruleset リンク

Spoke VNet への Forwarding Ruleset リンクを追加する場合:

```powershell
.\Setup-HybridDns.ps1 -LinkSpokeVnets
```

Hub とピアリングされている全 Spoke VNet に Ruleset をリンクする。

### 6.3 オプション: Cloud VM 名前解決

Spoke VM の名前を on-prem から解決したい場合:

```powershell
.\Setup-HybridDns.ps1 -EnableCloudVmResolution
```

`azure.internal` の Private DNS Zone と条件付きフォワーダーを構成する。

### 6.4 DNS 構成の確認

```powershell
.\scripts\Verify-HybridDns.ps1
```

Spoke VNet リンクも検証する場合:

```powershell
.\scripts\Verify-HybridDns.ps1 -LinkSpokeVnets
```

Cloud VM 名前解決も検証する場合:

```powershell
.\scripts\Verify-HybridDns.ps1 -EnableCloudVmResolution
```

---

## 7. 運用スクリプト

### 7.1 疑似オンプレ環境（`infra/nested/onprem/`）

| スクリプト | 用途 |
|-----------|------|
| `scripts/Upload-VHDs.ps1` | VHD → Managed Disk アップロード (ローカル PC) |
| `scripts/Verify-OnpremSetup.ps1` | 環境検証 (ローカル PC) |
| `scripts/host/Setup-NestedEnvironment.ps1` | 一括セットアップ (ステップ 4.5〜4.8 相当) |
| `scripts/host/Setup-NestedNetwork.ps1` | ネスト VM 用ネットワーク構成 |
| `scripts/host/Create-NestedVMs.ps1` | ネスト VM 自動作成 |
| `scripts/host/Configure-StaticIPs.ps1` | ゲスト VM 固定 IP 設定 |
| `scripts/host/Install-ADDS.ps1` | AD DS インストール・DC 昇格 |
| `scripts/host/Join-Domain.ps1` | ドメイン参加 |
| `scripts/host/Install-SqlServer.ps1` | SQL Server インストール (vm-sql01) |

### 7.2 VPN & DNS（`infra/nested/network/`）

| スクリプト | 用途 |
|-----------|------|
| `Setup-HybridDns.ps1` | Hybrid DNS 構成（作成） |
| `scripts/Verify-VpnConnection.ps1` | VPN 接続の検証 |
| `scripts/Verify-HybridDns.ps1` | DNS 構成の検証 |
| `scripts/Reset-VpnConnection.ps1` | VPN 接続のリセット（GW 保持、LGW + Connection 削除） |
| `scripts/Remove-HybridDns.ps1` | DNS 構成の削除（Setup-HybridDns の逆操作） |

### 7.3 VPN 接続のリセット

VPN 接続に問題がある場合、Connection と LGW のみを削除して再デプロイできる。VPN Gateway（作成に 30-45 分かかる）は保持される。

```powershell
# リセット（Connection + LGW を削除）
.\scripts\Reset-VpnConnection.ps1

# 再接続（main.bicep 再デプロイで LGW + Connection のみ再作成）
$env:VPN_SHARED_KEY = '<your-shared-key>'
az deployment sub create -l japaneast -f main.bicep -p main.bicepparam
```

### 7.4 DNS 構成の削除

```powershell
# DNS 構成を完全削除
.\scripts\Remove-HybridDns.ps1

# DNS Server ロールを保持して削除
.\scripts\Remove-HybridDns.ps1 -KeepDnsServerRole
```

---

## 8. ファイル構成

### 疑似オンプレ環境（`infra/nested/onprem/`）

```
├── main.bicep              # メインテンプレート
├── main.bicepparam         # パラメータファイル
├── modules/
│   ├── network.bicep       # VNet, サブネット, NSG, NAT Gateway
│   ├── bastion.bicep       # Azure Bastion
│   └── hyperv-host.bicep   # Hyper-V ホスト VM
├── _Invoke-OnHost.ps1          # ラッパーの Run Command ヘルパー (ローカル PC)
├── 01-Setup-Network.ps1        # ラッパー: ネットワーク構成
├── 02-Create-VMs.ps1           # ラッパー: VM 作成 (非同期)
├── 03-Start-VMs.ps1            # ラッパー: VM 起動
├── 04-Configure-IPs.ps1        # ラッパー: 固定 IP 設定
├── 05-Install-ADDS.ps1         # ラッパー: AD DS インストール
├── 06-Join-Domain.ps1          # ラッパー: ドメイン参加
├── scripts/
│   ├── Upload-VHDs.ps1         # VHD → Managed Disk アップロード (ローカル PC)
│   ├── Verify-OnpremSetup.ps1  # 環境検証 (ローカル PC)
│   └── host/                   # ホスト VM 上で実行するスクリプト
│       ├── Setup-NestedEnvironment.ps1  # 一括セットアップ (ステップ 4.5〜4.8 相当)
│       ├── Setup-NestedNetwork.ps1  # ネスト VM 用ネットワーク構成
│       ├── Create-NestedVMs.ps1     # ネスト VM 自動作成
│       ├── Configure-StaticIPs.ps1  # ゲスト VM 固定 IP 設定
│       ├── Install-ADDS.ps1         # AD DS インストール・DC 昇格
│       ├── Join-Domain.ps1          # ドメイン参加
│       ├── Install-SqlServer.ps1    # SQL Server インストール
│       └── Setup-HybridDns.ps1      # ハイブリッド DNS 構成
```

### VPN & DNS（`infra/nested/network/`）

```
├── main.bicep              # VPN デプロイテンプレート (subscription scope)
├── main.bicepparam         # パラメータファイル
├── main.json               # ARM テンプレート (コンパイル済み)
├── Setup-HybridDns.ps1     # Hybrid DNS セットアップスクリプト
├── modules/
│   ├── get-pip-ip.bicep           # Public IP アドレス取得
│   ├── local-network-gateway.bicep # LGW モジュール
│   ├── update-hub-peering.bicep   # Hub-Spoke Peering 更新
│   └── vpn-routes.bicep           # GatewaySubnet ルート設定
└── scripts/
    ├── Verify-VpnConnection.ps1   # VPN 接続検証
    ├── Verify-HybridDns.ps1       # DNS 構成検証
    ├── Reset-VpnConnection.ps1    # VPN 接続リセット
    └── Remove-HybridDns.ps1       # DNS 構成削除
```

---

## 備考: SQL Server のインストール

セットアップ手順（ステップ 4.5〜4.7 / 一括セットアップ）には SQL Server のインストールは含まれていない。vm-sql01 への SQL Server インストールは、ドメイン参加完了後に別途実施する。

### 方法 A: ホスト VM からスクリプトで実行（推奨）

Bastion RDP でホスト VM に接続し、`Install-SqlServer.ps1` を実行する。PowerShell Direct 経由で vm-sql01 にインストールされる。

```powershell
# SQL Server 2022 Developer Edition をダウンロード＆インストール
.\scripts\host\Install-SqlServer.ps1 -Version 2022

# sa を無効化し、専用の管理者ログインを作成する場合
.\scripts\host\Install-SqlServer.ps1 -Version 2022 -DisableSa -SqlAdminPassword 'Adm1nP@ss!'

# ISO からインストールする場合（SQL Server 2025 等）
.\scripts\host\Install-SqlServer.ps1 -IsoPath 'F:\ISO\SQLServer2025-x64-ENU-Dev.iso'
```

> `-Version` モードは Microsoft からブートストラッパーを自動ダウンロードする。`-IsoPath` モードは Visual Studio サブスクリプション等で取得した ISO を使用する。

### 方法 B: ゲスト VM に直接インストール

Hyper-V マネージャーで vm-sql01 に接続し、ゲスト OS 上で手動インストールする。ISO をマウントして `setup.exe` を実行するか、[SQL Server ダウンロードページ](https://www.microsoft.com/ja-jp/sql-server/sql-server-downloads)から Developer Edition インストーラーを取得して実行する。

---

## 備考: 一括セットアップ（Hyper-V ホストから実行）

`Setup-NestedEnvironment.ps1` は、ネットワーク構成・VM 作成・OOBE 自動化・固定 IP・AD DS・ドメイン参加・検証まで（ステップ 4.5〜4.7 相当）を一括実行するスクリプト。

`unattend.xml` を VHDX に注入して OOBE を自動化するため、手動での OOBE 操作は不要。`unattend.xml` には Administrator パスワード（既定: `P@ssW0rd1234!`）が含まれ、後続の PowerShell Direct 接続で使用される。パスワードはスクリプト上部の `$cfg.SetupPassword` で変更可能。

> **前提**:
> - ステップ 4.1〜4.3 が完了していること（Bicep デプロイ、Hyper-V 有効化後の再起動、VHD アップロード）

### セットアップスクリプトを VM に配置

ローカル PC からスクリプトを Base64 エンコードし、Managed Run Command で VM 上にフォルダごと作成する。

```powershell
# スクリプトを Base64 エンコード
$scriptPath = "scripts/host/Setup-NestedEnvironment.ps1"
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($scriptPath))

# Base64 を埋め込んだ一時スクリプトを作成
$deployScript = "$env:TEMP\deploy-to-vm.ps1"
@"
New-Item -Path C:\NestedSetup -ItemType Directory -Force | Out-Null
`$b64 = '$b64'
[IO.File]::WriteAllBytes('C:\NestedSetup\Setup-NestedEnvironment.ps1', [Convert]::FromBase64String(`$b64))
Write-Output "File written: `$((Get-Item 'C:\NestedSetup\Setup-NestedEnvironment.ps1').Length) bytes"
"@ | Set-Content -Path $deployScript -Encoding UTF8

# Managed Run Command で VM 上に配置
az vm run-command create `
    --resource-group rg-onprem-nested `
    --vm-name vm-onprem-nested-hv01 `
    --name deployScript `
    --script "@$deployScript" `
    --async-execution false
```

> **注意**: スクリプトに日本語が含まれるため、UTF-8 BOM 付きで保存されている必要がある。BOM なしの場合、Windows PowerShell 5.1 でパースエラーになる。

### 配置結果を確認

```powershell
az vm run-command invoke `
    --resource-group rg-onprem-nested `
    --name vm-onprem-nested-hv01 `
    --command-id RunPowerShellScript `
    --scripts "Get-ChildItem C:\NestedSetup | Format-Table Name, Length, LastWriteTime -AutoSize"
```

### Run Command リソースのクリーンアップ

配置に使用した Managed Run Command リソースを削除する。

```powershell
az vm run-command delete `
    --resource-group rg-onprem-nested `
    --vm-name vm-onprem-nested-hv01 `
    --name deployScript --yes
```

### セットアップスクリプトの実行

Bastion RDP でホスト VM に接続し、**管理者権限の PowerShell** で `C:\NestedSetup` から実行する。

```powershell
cd C:\NestedSetup
.\Setup-NestedEnvironment.ps1
```

スクリプトがステップ 4.5〜4.7 相当の処理を順に実行する。OOBE は `unattend.xml` により自動化されるため、手動操作は不要。

> **途中再開**: フェーズ途中で失敗した場合、`-StartFromPhase` で再開できる。
> ```powershell
> .\Setup-NestedEnvironment.ps1 -StartFromPhase 5
> ```

> **パスワード変更**: セットアップ完了時にゲスト VM のパスワードを変更する場合:
> ```powershell
> .\Setup-NestedEnvironment.ps1 -NewPassword 'MyN3wP@ss!'
> ```

> **確認スキップ**: `-Force` で開始前の確認プロンプトをスキップできる。
> ```powershell
> .\Setup-NestedEnvironment.ps1 -Force
> ```

### アップロードディスクのクリーンアップ

セットアップ完了後、不要になったアップロード用 Managed Disk を削除する（スクリプト実行後に表示されるコマンドを参照）。

```powershell
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2022
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2019
az disk delete -g rg-onprem-nested -n disk-upload-ws2022 --yes
az disk delete -g rg-onprem-nested -n disk-upload-ws2019 --yes
```

---

## 注意点

### ドメイン名 `.local` について

既定のドメイン名 `contoso.local` は `.local` サフィックスを使用しています。Microsoft の公式ドキュメントでは `.local` の使用は非推奨とされていますが、本環境は **Windows のみ・閉域・一時的なラボ** であるため、影響は限定的と判断し採用しています。

`.local` の既知の問題:

- **mDNS (Multicast DNS) との競合**: `.local` は RFC 6762 で mDNS 用に予約されており、Linux / macOS クライアントで DNS 解決が失敗・遅延する場合がある (本環境は Windows のみのため該当なし)
- **非ルーティング**: `.local` はインターネット上でルーティングされないため、パブリック CA による SSL 証明書の発行不可 (閉域環境のため該当なし)
- **Entra Domain Services**: マネージドドメインでは `.local` が非推奨

本番環境やマルチプラットフォーム環境では、所有ドメインのサブドメイン (例: `ad.contoso.com`) または RFC 2606 予約ドメイン (例: `corp.example.com`) の使用を推奨します。

------

## 参考

- [応答ファイル (unattend.xml) の作成 - Microsoft Learn](https://learn.microsoft.com/ja-jp/windows-hardware/manufacture/desktop/update-windows-settings-and-scripts-create-your-own-answer-file-sxs?view=windows-11)
- [Azure VPN Gateway ドキュメント](https://learn.microsoft.com/azure/vpn-gateway/)
- [Azure DNS Private Resolver](https://learn.microsoft.com/azure/dns/dns-private-resolver-overview)
- 関連テンプレート: [`infra/network/`](../../infra/network/) — 通常のオンプレ環境用 VPN
