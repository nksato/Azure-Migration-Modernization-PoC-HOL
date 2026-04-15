# VPN & Hybrid DNS — Nested Hyper-V 環境 (onprem-nested ↔ Hub)

疑似オンプレ環境 (`rg-onprem-nested`) と Azure Hub (`rg-hub`) を S2S VPN で接続し、  
ハイブリッド DNS を構成する。

## アーキテクチャ

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

### DNS フロー

```
Cloud → contoso.local:
  Spoke VM → Hub DNS Resolver (Outbound) → Forwarding Ruleset (frs-onprem)
    → VPN → Host (vm-onprem-nested-hv01:53) → vm-ad01 (192.168.100.10)

On-prem → privatelink.*:
  vm-app01/vm-sql01 → vm-ad01 (条件付きフォワーダー)
    → VPN → Hub DNS Resolver (Inbound) → Private DNS Zone

On-prem → azure.internal (オプション):
  vm-ad01 → VPN → Hub DNS Resolver (Inbound) → Private DNS Zone (azure.internal)
```

## 前提条件

1. Nested Hyper-V 環境がデプロイ済み（`infra/nested/onprem/main.bicep`）
2. クラウド環境がデプロイ済み（`infra/cloud/main.bicep`）
   - `rg-hub` に `vnet-hub`（GatewaySubnet 含む）
   - `rg-spoke1` 〜 `rg-spoke4` に各 VNet
3. Azure CLI ログイン済み（`az login`）

## 使用パターン

### A) Standalone モード（デフォルト）

onprem-nested のみを Hub に接続する場合。Hub VPN Gateway を新規作成する。

```
createHubVpnGateway = true  (デフォルト)
```

### B) Dual モード

`infra/network/` で既に Hub VPN Gateway を作成済みの場合。  
既存の Hub GW を共有し、onprem と onprem-nested の両方を Hub に接続する。

```powershell
# main.bicepparam で以下のコメントを外す:
# param createHubVpnGateway = false
```

> **注意**: Dual モードでは Hub GW の LGW が 2 つ（`lgw-onprem` + `lgw-onprem-nested`）になる。

## デプロイ手順

### 1. VPN デプロイ

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

### 2. VPN 接続の確認

```powershell
.\scripts\Verify-VpnConnection.ps1
```

Spoke からの到達性も検証する場合:

```powershell
.\scripts\Verify-VpnConnection.ps1 -TestSpokeReachability
```

### 3. Hybrid DNS セットアップ

VPN 接続が確立された後、Hybrid DNS を構成する。

```powershell
.\Setup-HybridDns.ps1
```

スクリプトの実行ステップ:

| ステップ | 実行先 | 内容 |
|---------|--------|------|
| [1] | Cloud | DNS Forwarding Ruleset (`frs-onprem`) 作成 |
| [2] | Cloud | Forwarding Rule 追加（`contoso.local` → Host IP） |
| [3] | Cloud | Ruleset に VNet リンク（Hub + 全 Spoke） |
| [4] | Cloud | Spoke VNet の DNS 設定を Hub DNS Resolver IP に変更 |
| [5] | On-prem | Host に DNS Server ロールをインストール |
| [6] | On-prem | Host の DNS クライアントに vm-ad01 IP を追加 |
| [7] | On-prem | Host に条件付きフォワーダー（`contoso.local` → vm-ad01） |
| [8] | On-prem | vm-ad01 に条件付きフォワーダー（`privatelink.*` → Hub DNS Resolver） |
| [9] | 検証 | 名前解決テスト（contoso.local, privatelink.*） |

#### Cloud VM 名前解決（オプション）

Spoke VM の名前を on-prem から解決したい場合:

```powershell
.\Setup-HybridDns.ps1 -EnableCloudVmResolution
```

追加ステップ [10]-[11] で `azure.internal` の Private DNS Zone と条件付きフォワーダーを構成する。

### 4. DNS 構成の確認

```powershell
.\scripts\Verify-HybridDns.ps1
```

Cloud VM 名前解決も検証する場合:

```powershell
.\scripts\Verify-HybridDns.ps1 -EnableCloudVmResolution
```

## 運用スクリプト

| スクリプト | 用途 |
|-----------|------|
| `Setup-HybridDns.ps1` | Hybrid DNS 構成（作成） |
| `scripts/Verify-VpnConnection.ps1` | VPN 接続の検証 |
| `scripts/Verify-HybridDns.ps1` | DNS 構成の検証 |
| `scripts/Reset-VpnConnection.ps1` | VPN 接続のリセット（GW 保持、LGW + Connection 削除） |
| `scripts/Remove-HybridDns.ps1` | DNS 構成の削除（Setup-HybridDns の逆操作） |

### VPN 接続のリセット

VPN 接続に問題がある場合、Connection と LGW のみを削除して再デプロイできる。  
VPN Gateway（作成に 30-45 分かかる）は保持される。

```powershell
# リセット（Connection + LGW を削除）
.\scripts\Reset-VpnConnection.ps1

# 再接続（main.bicep 再デプロイで LGW + Connection のみ再作成）
$env:VPN_SHARED_KEY = '<your-shared-key>'
az deployment sub create -l japaneast -f main.bicep -p main.bicepparam
```

### DNS 構成の削除

```powershell
# DNS 構成を完全削除
.\scripts\Remove-HybridDns.ps1

# DNS Server ロールを保持して削除
.\scripts\Remove-HybridDns.ps1 -KeepDnsServerRole
```

## ファイル構成

```
infra/nested/network/
├── main.bicep              # VPN デプロイテンプレート (subscription scope)
├── main.bicepparam         # パラメータファイル
├── main.json               # ARM テンプレート (コンパイル済み)
├── Setup-HybridDns.ps1     # Hybrid DNS セットアップスクリプト
├── README.md               # このファイル
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

## 参考情報

- [Azure VPN Gateway ドキュメント](https://learn.microsoft.com/azure/vpn-gateway/)
- [Azure DNS Private Resolver](https://learn.microsoft.com/azure/dns/dns-private-resolver-overview)
- 関連テンプレート: [`infra/network/`](../../network/) — 通常のオンプレ環境用 VPN
