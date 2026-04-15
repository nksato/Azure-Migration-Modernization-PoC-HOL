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

> **ISO → VHD 変換**: ISO はインストールメディアのため、そのままでは使用できません。固定サイズ VHD への変換が必要です。
> - [Convert-WindowsImage を使用した VHD の作成](https://learn.microsoft.com/ja-jp/microsoft-desktop-optimization-pack/app-v/appv-auto-provision-a-vm)
> - [DISM イメージ管理コマンド](https://learn.microsoft.com/ja-jp/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14?view=windows-11)

> **注意**: Azure VM のライセンスはゲスト VM をカバーしません。Nested Hyper-V 上で Windows Server を実行する場合、上記いずれかの方法で適切なライセンスを確保してください。

## デプロイ手順

### 1. リソースグループ作成

```bash
az group create --name rg-onprem-nested --location japaneast
```

### 2. デプロイ実行

```powershell
az deployment group create `
  --resource-group rg-onprem-nested `
  --template-file main.bicep `
  --parameters main.bicepparam `
  --parameters adminPassword='<YOUR_PASSWORD>'
```

> `adminUsername` は `main.bicepparam` で変更可能です。
>
> **注意**: ここで設定する `adminPassword` は **Hyper-V ホスト VM**（Bastion RDP 接続用）のパスワードです。ゲスト VM（vm-ad01 等）のパスワードとは別です。
> - **一括セットアップ**: ゲスト VM のパスワードは `Setup-NestedEnvironment.ps1` が `unattend.xml` 経由で自動設定します（`P@ssW0rd1234!`）。
> - **ステップ実行**: ステップ 8 の OOBE 時に手動で `P@ssW0rd1234!` を設定してください。

### 3. Hyper-V ホスト VM への接続

デプロイ完了後、VM は自動的に再起動して Hyper-V が有効化されます。再起動完了後、Bastion 経由で接続します。

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

または Azure Portal から Bastion 経由で RDP 接続してください。

### 4. ネスト VM 用ネットワーク設定

Bastion RDP または `az vm run-command` のいずれかで実行可能です。

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

> 動的 VHD や VHDX 形式の場合、事前に変換が必要です（**管理者権限の PowerShell** で実行。Hyper-V 機能の有効化が必要）:
> ```powershell
> Convert-VHD -Path .\dynamic.vhdx -DestinationPath .\fixed.vhd -VHDType Fixed
> ```

### 6. ネスト VM の作成

VHDX 変換に数分かかるため、`az vm run-command` の場合はタイムアウトに注意してください。

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

> **ヒント**: 一括セットアップ（`Setup-NestedEnvironment.ps1`）を使用する場合、以下のステップ 8 は不要です。一括セットアップでは OOBE が `unattend.xml` で自動化されます。「[一括セットアップ（リモート PC から実行）](#一括セットアップリモート-pc-から実行)」を参照してください。

Bastion RDP でホスト VM に接続し、各 VM を起動して OOBE（初期セットアップ）を完了した後、以下のスクリプトを順に実行します。

> **重要**: OOBE で設定する Administrator パスワードは `P@ssW0rd1234!` (本 HOL 内スクリプト内にハードコードしている値)にしてください。後続のスクリプトがこのパスワードで PowerShell Direct 接続を行います。

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

Hyper-V マネージャーで各 VM に接続し OOBE（初期セットアップ）を完了します。

**(3) 固定 IP 設定 → (4) AD DS インストール → (5) ドメイン参加** を順に実行します。

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

## 一括セットアップ（リモート PC から実行）

`Setup-NestedEnvironment.ps1` は、ネットワーク構成・VM 作成・OOBE 自動化・固定 IP・AD DS・ドメイン参加・検証まで（Phase 1〜8）を一括実行するスクリプトです。

`unattend.xml` を VHDX に注入して OOBE を自動化するため、手動での OOBE 操作は不要です。

> **前提**:
> - ステップ 1〜2 のデプロイと、VM の再起動（Hyper-V 有効化）が完了していること
> - Windows Server VHD を入手済みであること

### (1) セットアップスクリプトを VM に配置

ローカル PC からスクリプトを Base64 エンコードし、Managed Run Command で VM 上にフォルダごと作成します。

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

> **注意**: スクリプトに日本語が含まれるため、UTF-8 BOM 付きで保存されている必要があります。BOM なしの場合、Windows PowerShell 5.1 でパースエラーになります。

### (2) 配置結果を確認

```powershell
az vm run-command invoke `
    --resource-group rg-onprem-nested `
    --name vm-onprem-nested-hv01 `
    --command-id RunPowerShellScript `
    --scripts "Get-ChildItem C:\NestedSetup | Format-Table Name, Length, LastWriteTime -AutoSize"
```

### (3) Run Command リソースのクリーンアップ

配置に使用した Managed Run Command リソースを削除します。

```powershell
az vm run-command delete `
    --resource-group rg-onprem-nested `
    --vm-name vm-onprem-nested-hv01 `
    --name deployScript --yes
```

### (4) VHD イメージのアップロード

VHD のアップロードはセットアップスクリプト実行前に完了させてください（Phase 2 でアップロード済みディスクを検出します）。

```powershell
.\scripts\Upload-VHDs.ps1 `
    -VhdPathWs2022 "C:\path\to\ws2022.vhd" `
    -VhdPathWs2019 "C:\path\to\ws2019.vhd"
```

### (5) セットアップスクリプトの実行

Bastion RDP でホスト VM に接続し、**管理者権限の PowerShell** で `C:\NestedSetup` から実行します。

```powershell
cd C:\NestedSetup
.\Setup-NestedEnvironment.ps1
```

スクリプトが Phase 1〜8 を順に実行します。OOBE は `unattend.xml` により自動化されるため、手動操作は不要です。

> **途中再開**: フェーズ途中で失敗した場合、`-StartFromPhase` で再開できます。
> ```powershell
> .\Setup-NestedEnvironment.ps1 -StartFromPhase 5
> ```

> **パスワード変更**: セットアップ完了時にゲスト VM のパスワードを変更する場合:
> ```powershell
> .\Setup-NestedEnvironment.ps1 -NewPassword 'MyN3wP@ss!'
> ```

> **確認スキップ**: `-Force` で開始前の確認プロンプトをスキップできます。
> ```powershell
> .\Setup-NestedEnvironment.ps1 -Force
> ```

### (6) アップロードディスクのクリーンアップ

セットアップ完了後、不要になったアップロード用 Managed Disk を削除します（スクリプト実行後に表示されるコマンドを参照）。

```powershell
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2022
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n disk-upload-ws2019
az disk delete -g rg-onprem-nested -n disk-upload-ws2022 --yes
az disk delete -g rg-onprem-nested -n disk-upload-ws2019 --yes
```

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
│       ├── Setup-NestedEnvironment.ps1  # 一括セットアップ (Phase 1-8)
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

VPN 関連のテンプレート・スクリプトは `infra/nested/network/` に分離されています。
詳細は [infra/nested/network/](../network/) を参照してください。
