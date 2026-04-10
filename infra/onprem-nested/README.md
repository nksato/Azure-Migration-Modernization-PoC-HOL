# Azure Migration - Nested Hyper-V 疑似オンプレ環境 (作成中)

Azure 上に閉域の疑似オンプレミス環境を構築し、Azure Migrate 等による移行検証に使用します。

## アーキテクチャ

```
VNet (10.1.0.0/16) - 閉域ネットワーク
├── AzureBastionSubnet (10.1.0.0/26)
│   └── Azure Bastion (Standard) ... 管理アクセス用
└── snet-onprem (10.1.1.0/24)      ... UDR でインターネット遮断
    └── Hyper-V Host VM (Windows Server 2022, Standard_E4s_v5)
        ├── F: ドライブ (256 GB データディスク)
        ├── InternalNAT Switch (192.168.100.0/24)
        ├── vm-ad01  (WS2022) ... AD DS     192.168.100.10
        ├── vm-app01 (WS2019) ... App       192.168.100.11
        └── vm-sql01 (WS2019) ... SQL       192.168.100.12
```

### 閉域ネットワーク構成

| 制御 | 内容 |
|------|------|
| UDR | `0.0.0.0/0 → None` でインターネット向け通信を破棄 |
| NSG | `Internet` サービスタグへの送信を Deny |
| Public IP | VM には付与しない |

## 前提条件

- Azure CLI (`az`) がインストール済み
- azcopy がインストール済み（VHD アップロードに使用）
- Azure サブスクリプションへのログイン済み (`az login`)
- Contributor 以上のロール
- Windows Server 2022 / 2019 の固定サイズ VHD ファイル

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

### 3. Hyper-V ホスト VM への接続

デプロイ完了後、VM は自動的に再起動して Hyper-V が有効化されます。再起動完了後、Bastion 経由で接続します。

```bash
az network bastion rdp \
  --name bas-onprem \
  --resource-group rg-onprem-nested \
  --target-resource-id <VM_RESOURCE_ID>
```

または Azure Portal から Bastion 経由で RDP 接続してください。

### 4. ネスト VM 用ネットワーク設定

Hyper-V ホスト VM に接続後、管理者 PowerShell で以下を実行します:

```powershell
.\scripts\Setup-NestedNetwork.ps1
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

**Hyper-V ホスト VM 上** で管理者 PowerShell から実行します:

```powershell
.\scripts\Create-NestedVMs.ps1
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
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-hv01 -n disk-upload-ws2022
az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-hv01 -n disk-upload-ws2019
az disk delete -g rg-onprem-nested -n disk-upload-ws2022 --yes
az disk delete -g rg-onprem-nested -n disk-upload-ws2019 --yes
```

### 8. ゲスト OS セットアップ

各 VM を起動し、初期設定を行います:

1. **vm-ad01**: AD DS インストール、ドメイン作成
2. **vm-app01**: ドメイン参加、アプリケーション配置
3. **vm-sql01**: ドメイン参加、SQL Server インストール

## ファイル構成

```
├── main.bicep              # メインテンプレート
├── main.bicepparam         # パラメータファイル
├── modules/
│   ├── network.bicep       # VNet, サブネット, NSG, UDR
│   ├── bastion.bicep       # Azure Bastion
│   └── hyperv-host.bicep   # Hyper-V ホスト VM
├── scripts/
│   ├── Upload-VHDs.ps1          # VHD → Managed Disk アップロード (ローカル PC)
│   ├── Setup-NestedNetwork.ps1  # ネスト VM 用ネットワーク構成 (ホスト VM)
│   └── Create-NestedVMs.ps1     # ネスト VM 自動作成 (ホスト VM)
└── README.md
```

## VM サイズの目安

| サイズ | vCPU | メモリ | 推奨用途 |
|--------|------|--------|----------|
| Standard_E4s_v5 | 4 | 32 GB | ネスト VM 1-2 台 |
| Standard_E8s_v5 | 8 | 64 GB | ネスト VM 3-4 台 |
| Standard_E16s_v5 | 16 | 128 GB | ネスト VM 5 台以上 |

## VPN 接続

### 接続パターン

| パターン | `createHubVpnGateway` | 説明 |
|----------|----------------------|------|
| **Dual** (推奨) | `false` (デフォルト) | 既存の onprem + Hub VPN GW を共有。接続追加のみ |
| **Standalone** | `true` | Hub VPN GW を新規作成。onprem-nested 単体で完結 |

### Dual パターン（onprem + onprem-nested → Hub）

```bash
# 前提: infra/network/ で Hub VPN GW (vpngw-hub) が作成済み
$env:VPN_SHARED_KEY = '<your-shared-key>'
az deployment sub create -l japaneast -f vpn-deploy.bicep -p vpn-deploy.bicepparam
```

### Standalone パターン（onprem-nested のみ → Hub）

```bash
$env:VPN_SHARED_KEY = '<your-shared-key>'
az deployment sub create -l japaneast -f vpn-deploy.bicep -p vpn-deploy.bicepparam \
  -p createHubVpnGateway=true
```

### VPN 削除

```powershell
# Dual: Hub VPN GW は残す
.\scripts\Remove-Vpn.ps1

# Standalone: Hub VPN GW も削除
.\scripts\Remove-Vpn.ps1 -IncludeHubGateway
```
