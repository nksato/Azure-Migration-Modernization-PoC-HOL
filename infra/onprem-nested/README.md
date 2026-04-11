# Azure Migration - Nested Hyper-V 疑似オンプレ環境 (作成中)

Azure 上に疑似オンプレミス環境を構築し、Azure Migrate 等による移行検証に使用します。

## アーキテクチャ

```
VNet (10.1.0.0/16)
├── AzureBastionSubnet (10.1.0.0/26)
│   └── Azure Bastion (Standard) ... 管理アクセス用
└── snet-onprem-nested (10.1.1.0/24) ... NAT Gateway で送信インターネット
    ├── NAT Gateway (ng-onprem-nested) ... 送信インターネットアクセス
    └── Hyper-V Host VM (Windows Server 2022, Standard_E4s_v5)
        ├── F: ドライブ (256 GB データディスク)
        ├── InternalNAT Switch (192.168.100.0/24)
        ├── vm-ad01  (WS2022) ... AD DS     192.168.100.10
        ├── vm-app01 (WS2019) ... App       192.168.100.11
        └── vm-sql01 (WS2019) ... SQL       192.168.100.12
```

### ネットワーク構成

| 制御 | 内容 |
|------|------|
| NAT Gateway | `ng-onprem-nested` で送信インターネットアクセスを提供 |
| NSG (VM) | `nsg-onprem-nested` — `AllowVNetInbound` + `DenyInternetInbound` で受信を制限 |
| NSG (Bastion) | `nsg-bas-onprem-nested` — Standard SKU では Bastion サブネットに NSG が必須 |
| Public IP | VM には付与しない（`defaultOutboundAccess: false`） |

### Bastion SKU

Bastion は **Standard** SKU を使用しています。Nested Hyper-V 内のゲスト VM へ Bastion 経由で PowerShell Direct を実行する場合、Standard 以上の SKU が必要です（Basic ではネイティブクライアント接続が非対応）。Standard SKU では Bastion サブネットに NSG の明示的な設定が必須となるため、`nsg-bas-onprem-nested` を構成しています。

## 前提条件

- Azure CLI (`az`) がインストール済み
- azcopy がインストール済み（VHD アップロードに使用）
- Azure サブスクリプションへのログイン済み (`az login`)
- Contributor 以上のロール
- Windows Server 2022 / 2019 の固定サイズ VHD ファイル

## Windows Server VHD の入手

Nested Hyper-V のゲスト VM は Azure VM ではないため、Azure Marketplace から OS イメージを直接デプロイすることはできません。
ゲスト VM 用の Windows Server VHD/ISO を別途入手し、ライセンス条件に従って使用する必要があります。

### 入手方法

| 方法 | 費用 | 有効期間 | 入手形式 | 備考 |
|------|------|---------|---------|------|
| **Evaluation Center (体験版)** | 無料 | 180 日 | ISO / VHD | 評価目的のみ。VHD 形式なら変換不要 |
| **Visual Studio サブスクリプション** | サブスク費用 | サブスク有効中 | ISO | 開発/テスト目的。ISO → VHD 変換が必要 |

- **Evaluation Center**: https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server
- **Visual Studio サブスクリプション**: https://my.visualstudio.com/Downloads

> **注意**: Azure VM のライセンスはゲスト VM をカバーしません。Nested Hyper-V 上で Windows Server を実行する場合、上記いずれかの方法で適切なライセンスを確保してください。

## デプロイ手順

### 1. リソースグループ作成

```bash
az group create --name rg-onprem-nested --location japaneast
```

### 2. デプロイ実行

```bash
az deployment group create \
  --resource-group rg-onprem-nested \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters adminPassword='<YOUR_PASSWORD>'
```

> `adminUsername` は `main.bicepparam` で変更可能です。
>
> **注意**: ここで設定する `adminPassword` は **Hyper-V ホスト VM**（Bastion RDP 接続用）のパスワードです。ゲスト VM（vm-ad01 等）のパスワードとは別です。ゲスト VM のパスワードはステップ 8 の OOBE 時に `P@ssW0rd1234!` を設定してください。

### 3. Hyper-V ホスト VM への接続

デプロイ完了後、VM は自動的に再起動して Hyper-V が有効化されます。再起動完了後、Bastion 経由で接続します。

```bash
az network bastion rdp \
  --name bas-onprem-nested \
  --resource-group rg-onprem-nested \
  --target-resource-id <VM_RESOURCE_ID>
```

または Azure Portal から Bastion 経由で RDP 接続してください。

### 4. ネスト VM 用ネットワーク設定

Hyper-V ホスト VM 上で管理者権限で実行します（Bastion RDP または `az vm run-command` のいずれかで実行可能）:

```powershell
# Bastion RDP で接続して実行する場合
.\scripts\host\Setup-NestedNetwork.ps1

# az vm run-command で実行する場合 (ラッパースクリプト)
.\01-Setup-Network.ps1

# az vm run-command を直接実行する場合
az vm run-command invoke `
    --resource-group rg-onprem-nested `
    --name vm-onprem-nested-hv01 `
    --command-id RunPowerShellScript `
    --scripts @scripts/host/Setup-NestedNetwork.ps1
```

これにより以下が構成されます:
- 内部仮想スイッチ `InternalNAT`
- NAT (192.168.100.0/24)
- DHCP スコープ (192.168.100.100 - 200)

### 5. VHD イメージのアップロード

**ローカル PC** から VHD を Managed Disk としてアップロードし、Hyper-V ホストにアタッチします:

```powershell
.\scripts\Upload-VHDs.ps1 `
    -VhdPathWs2022 "C:\path\to\ws2022.vhd" `
    -VhdPathWs2019 "C:\path\to\ws2019.vhd"
```

> 動的 VHD や VHDX 形式の場合、事前に変換が必要です:
> ```powershell
> Convert-VHD -Path .\dynamic.vhdx -DestinationPath .\fixed.vhd -VHDType Fixed
> ```

### 6. ネスト VM の作成

Hyper-V ホスト VM 上で管理者権限で実行します（VHDX 変換に数分かかるため、`az vm run-command` の場合はタイムアウトに注意）:

```powershell
# Bastion RDP で接続して実行する場合
.\scripts\host\Create-NestedVMs.ps1

# az vm run-command で実行する場合 (ラッパースクリプト、非同期)
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

以下の 3 台のネスト VM が作成されます:

| VM 名 | OS | 役割 | vCPU | メモリ | IP |
|--------|------|------|------|--------|-----|
| vm-ad01 | WS 2022 | Active Directory | 2 | 4 GB | 192.168.100.10 |
| vm-app01 | WS 2019 | Application | 2 | 4 GB | 192.168.100.11 |
| vm-sql01 | WS 2019 | SQL Server | 2 | 8 GB | 192.168.100.12 |

### 7. アップロードディスクのクリーンアップ

ネスト VM 作成後、不要になったアップロード用 Managed Disk を削除してコスト削減:

```bash
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2022
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2019
az disk delete -g rg-onprem-nested -n disk-upload-ws2022 --yes
az disk delete -g rg-onprem-nested -n disk-upload-ws2019 --yes
```

### 8. ゲスト OS セットアップ

Bastion RDP でホスト VM に接続し、各 VM を起動して OOBE（初期セットアップ）を完了した後、以下のスクリプトを順に実行します。ステップ (3) 以降は Bastion 上で直接実行するか、`az vm run-command` で実行できます。

> **重要**: OOBE で設定する Administrator パスワードは `P@ssW0rd1234!` (本 HOL 内スクリプト内にハードコードしている値)にしてください。後続のスクリプトがこのパスワードで PowerShell Direct 接続を行います。

```powershell
# (1) 各 VM を起動
Start-VM vm-ad01, vm-app01, vm-sql01

# (2) Hyper-V マネージャーで各 VM に接続し OOBE を完了

# (3) 固定 IP 設定
.\scripts\host\Configure-StaticIPs.ps1       # Bastion 上で直接実行
.\04-Configure-IPs.ps1                       # ラッパー (az vm run-command)

# (4) AD DS インストール・DC 昇格 (vm-ad01 が自動再起動)
.\scripts\host\Install-ADDS.ps1              # Bastion 上で直接実行
.\05-Install-ADDS.ps1                        # ラッパー (az vm run-command)

# (5) ドメイン参加 (vm-app01, vm-sql01)
.\scripts\host\Join-Domain.ps1               # Bastion 上で直接実行
.\06-Join-Domain.ps1                         # ラッパー (az vm run-command)
```

#### パスワード埋め込みスクリプトについて

以下のスクリプトにはゲスト VM の認証用パスワード (`P@ssW0rd1234!`) がハードコードされています。

| スクリプト | パスワードの用途 |
|-----------|----------------|
| `Configure-StaticIPs.ps1` | ローカル Administrator でゲスト VM に PowerShell Direct 接続 |
| `Install-ADDS.ps1` | 同上 + DSRM (ディレクトリサービス復元モード) パスワード |
| `Join-Domain.ps1` | ローカル Administrator + ドメイン Administrator で接続 |
| `Setup-HybridDns.ps1` | ドメイン Administrator で DC に DNS 設定（パラメータ既定値） |
| `Verify-OnpremSetup.ps1` | 各ゲスト VM への接続検証 |

**理由**: これらのスクリプトは `az vm run-command` で非対話的に実行される場合があり、その中で `Invoke-Command -VMName`（PowerShell Direct）を使ってゲスト VM を操作します。非対話実行では資格情報のプロンプトを表示できないため、スクリプト内に埋め込んでいます。

> ⚠️ **本番環境では使用しないでください。** PoC / ハンズオン用の構成です。本番では Azure Key Vault 等からの取得を推奨します。

## ファイル構成

```
├── main.bicep              # メインテンプレート
├── main.bicepparam         # パラメータファイル
├── modules/
│   ├── network.bicep       # VNet, サブネット, NSG, NAT Gateway
│   ├── bastion.bicep       # Azure Bastion
│   └── hyperv-host.bicep   # Hyper-V ホスト VM
├── _Invoke-OnHost.ps1          # Run Command ヘルパー (ローカル PC)
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
│       ├── Setup-NestedNetwork.ps1  # ネスト VM 用ネットワーク構成
│       ├── Create-NestedVMs.ps1     # ネスト VM 自動作成
│       ├── Configure-StaticIPs.ps1  # ゲスト VM 固定 IP 設定
│       ├── Install-ADDS.ps1         # AD DS インストール・DC 昇格
│       ├── Join-Domain.ps1          # ドメイン参加
│       └── Setup-HybridDns.ps1      # ハイブリッド DNS 構成
└── README.md
```

## VM サイズの目安

| サイズ | vCPU | メモリ | 推奨用途 |
|--------|------|--------|----------|
| Standard_E4s_v5 | 4 | 32 GB | ネスト VM 1-2 台 |
| Standard_E8s_v5 | 8 | 64 GB | ネスト VM 3-4 台 |
| Standard_E16s_v5 | 16 | 128 GB | ネスト VM 5 台以上 |

## VPN 接続

VPN 関連のテンプレート・スクリプトは `infra/network-nested/` に分離されています。
詳細は [infra/network-nested/](../network-nested/) を参照してください。
