# Azure 参考価格 & スペック一覧

本ハンズオン環境をすべてデプロイした場合の Azure リソースの詳細スペックと月額コスト概算です。

> **注意**
>
> - 価格は **Japan East (東日本)** リージョン、**従量課金 (PAYG)** の概算です（2026 年 4 月時点）
> - 実際のコストはリージョン別の最新価格、データ転送量、稼働時間により変動します
> - 正確な見積もりには [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) をご利用ください
> - **PoC / ハンズオン環境のため、使い終わったらリソースグループごと削除してください**

---

## 全体サマリー

| 環境 | VM 数 | 月額 (USD) | 月額 (¥150換算) | 備考 |
|---|:---:|---:|---:|---|
| 疑似オンプレ (`rg-onprem`) | 3 | ~$492 | ~¥73,800 | DC + SQL + Web + Bastion + NAT GW |
| ネットワーク (VPN Gateway) | — | ~$365 | ~¥54,750 | VPN Gateway × 2 (OnPrem + Hub) |
| クラウド基盤 (`rg-hub`) | — | ~$382 | ~¥57,300 | Firewall + Bastion + DNS Resolver |
| Spoke1: Rehost | 2 | ~$107 | ~¥16,050 | VM 2 台 (Web + SQL) |
| Spoke2: DB PaaS 化 | 1 | ~$60 | ~¥9,000 | VM 1 台 + Azure SQL Basic |
| Spoke3: コンテナ化 | — | ~$10 | ~¥1,500 | ACR + Container Apps + Azure SQL |
| Spoke4: フル PaaS 化 | — | ~$18 | ~¥2,700 | App Service B1 + Azure SQL |
| **合計** | **6** | **~$1,434/月** | **~¥215,000/月** | |

---

## VM サイズ スペックシート

本プロジェクトで使用する VM サイズの比較一覧です。

| VM サイズ | シリーズ | vCPU | メモリ | 一時ストレージ | 最大データディスク | 最大 NIC | 最大ネットワーク帯域幅 | 用途 |
|---|---|:---:|---:|---:|:---:|:---:|---:|---|
| **Standard_D2s_v3** | Dsv3 (汎用) | 2 | 8 GB | 16 GB | 4 | 2 | 1,000 Mbps | オンプレ VM (DC/SQL/Web) |
| **Standard_B2s** | Bs (バースト可能) | 2 | 4 GB | 8 GB | 4 | 3 | 800 Mbps | Spoke Web VM |
| **Standard_B2ms** | Bs (バースト可能) | 2 | 8 GB | 16 GB | 4 | 3 | 1,500 Mbps | Spoke SQL VM |

> **D シリーズ vs B シリーズ**: D シリーズは一定のパフォーマンスを保証。B シリーズはバースト可能で、低負荷時にクレジットを蓄積し高負荷時に消費する。PoC/開発用途に最適。

---

## 1. 疑似オンプレ環境 (`rg-onprem`) — ~$492/月

### VM 構成

#### vm-onprem-ad (DC01) — ドメインコントローラー

| 項目 | スペック |
|---|---|
| **VM サイズ** | Standard_D2s_v3 (2 vCPU / 8 GB RAM) |
| **OS** | Windows Server 2022 Datacenter |
| **OS ディスク** | StandardSSD_LRS (E10, ~128 GB) |
| **データディスク** | なし |
| **NIC** | nic-vm-onprem-ad × 1 |
| **IP アドレス** | 10.0.1.4 (静的) |
| **役割** | Active Directory Domain Services + DNS |
| **ドメイン** | lab.local |
| **月額** | ~$137 (VM) + ~$10 (Disk) |

#### vm-onprem-sql (DB01) — データベースサーバー

| 項目 | スペック |
|---|---|
| **VM サイズ** | Standard_D2s_v3 (2 vCPU / 8 GB RAM) |
| **OS** | Windows Server 2019 (SQL Server 2019 イメージ) |
| **SQL Server** | SQL Server 2019 Developer Edition (ライセンス無料) |
| **OS ディスク** | StandardSSD_LRS (E10, ~128 GB) |
| **データディスク** | StandardSSD_LRS 128 GB × 1 (LUN 0) |
| **ディスク構成** | F:\SQLData (データ) / F:\SQLLog (ログ) |
| **NIC** | nic-vm-onprem-sql × 1 |
| **IP アドレス** | 10.0.1.5 (静的) |
| **ドメイン参加** | lab.local (AD 構築後に自動参加) |
| **月額** | ~$137 (VM) + ~$19 (Disk × 2) |

#### vm-onprem-web (APP01) — Web サーバー

| 項目 | スペック |
|---|---|
| **VM サイズ** | Standard_D2s_v3 (2 vCPU / 8 GB RAM) |
| **OS** | Windows Server 2019 Datacenter |
| **OS ディスク** | StandardSSD_LRS (E10, ~128 GB) |
| **データディスク** | なし |
| **NIC** | nic-vm-onprem-web × 1 |
| **IP アドレス** | 10.0.1.6 (静的) |
| **インストール済み** | IIS + ASP.NET 4.5 + .NET Framework 4.8 |
| **ドメイン参加** | lab.local (AD 構築後に自動参加) |
| **月額** | ~$137 (VM) + ~$10 (Disk) |

### ネットワーク・周辺構成

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **bas-onprem** | Azure Bastion Basic | ~$139 |
| **ng-onprem** | NAT Gateway Standard (アイドル 4 分) | ~$33 |
| **pip-bas-onprem** | Public IP Standard Static | ~$4 |
| **pip-ng-onprem** | Public IP Standard Static | ~$4 |
| **vnet-onprem** | 10.0.0.0/16 | $0 |
| **snet-onprem** | 10.0.1.0/24 (NSG + NAT GW 付き) | $0 |
| **AzureBastionSubnet** | 10.0.254.0/26 | $0 |
| **nsg-onprem** | VNet 内通信のみ許可 / インターネット受信拒否 | $0 |

---

## 2. ネットワーク (VPN Gateway) — ~$365/月

| リソース | SKU / スペック | 備考 | 月額 (USD) |
|---|---|---|---:|
| **vgw-onprem** | VPN Gateway VpnGw1 | オンプレ側、Generation 1 | ~$182 |
| **vpngw-hub** | VPN Gateway VpnGw1AZ | Hub 側、AZ 対応 | ~$182 |
| Public IP × 2 | Standard Static | 各 Gateway に 1 つ | ~$7 |
| Local Network Gateway × 2 | — | 対向の IP + アドレス空間定義 | $0 |
| VPN Connection × 2 | S2S (IPsec/IKE) | 双方向接続 | ~$1 |

#### VPN Gateway スペック比較

| 項目 | VpnGw1 | VpnGw1AZ |
|---|---|---|
| S2S トンネル数 | 最大 30 | 最大 30 |
| P2S 接続数 | 最大 250 | 最大 250 |
| 集約スループット | 650 Mbps | 650 Mbps |
| BGP サポート | あり | あり |
| アベイラビリティゾーン | なし | **対応** |

> VPN Gateway はデプロイに 30〜45 分。停止しても**継続課金**。不要時は削除推奨。

---

## 3. クラウド基盤 (`rg-hub`) — ~$382/月

| リソース | SKU / スペック | 備考 | 月額 (USD) |
|---|---|---|---:|
| **afw-hub** | Azure Firewall **Basic** | ルール: OnPrem↔Spokes 許可、DNS/HTTP/HTTPS 送信許可 | ~$219 |
| **bas-hub** | Azure Bastion **Basic** | Hub VNet 経由で Spoke VM にも接続可 | ~$139 |
| **dnspr-hub** | DNS Private Resolver | Inbound + Outbound の 2 エンドポイント | ~$14 |
| **log-hub** | Log Analytics Workspace | データ保持: 30 日 | ~$3 |
| **pip-afw-hub** | Public IP Standard Static | Firewall 用 | ~$4 |
| **pip-afw-hub-mgmt** | Public IP Standard Static | Firewall 管理用 (Basic SKU 必須) | ~$4 |
| Public IP (Bastion) | Standard Static | Bastion 用 | ~$4 |

### ネットワーク構成

| リソース | CIDR / 設定 | 用途 |
|---|---|---|
| **vnet-hub** | 10.10.0.0/16 | Hub VNet |
| AzureFirewallSubnet | 10.10.1.0/26 | Firewall データプレーン |
| AzureFirewallManagementSubnet | 10.10.4.0/26 | Firewall 管理 (Basic 必須) |
| AzureBastionSubnet | 10.10.2.0/26 | Bastion |
| GatewaySubnet | 10.10.255.0/27 | VPN Gateway |
| snet-dns-inbound | 10.10.5.0/28 | DNS Resolver Inbound |
| snet-dns-outbound | 10.10.5.16/28 | DNS Resolver Outbound |

### ルートテーブル

| Route Table | 適用先 | ルール |
|---|---|---|
| **rt-spokes-to-fw** | 全 Spoke サブネット | 0.0.0.0/0 → Firewall / 10.0.0.0/16 → Firewall |
| **rt-gateway-to-fw** | GatewaySubnet | Spoke CIDR → Firewall (対称ルーティング) |

### VNet Peering

| Peering | 方向 | Gateway Transit |
|---|---|---|
| Hub ↔ Spoke1 (10.20.0.0/16) | 双方向 | allowForwardedTraffic: true |
| Hub ↔ Spoke2 (10.21.0.0/16) | 双方向 | allowForwardedTraffic: true |
| Hub ↔ Spoke3 (10.22.0.0/16) | 双方向 | allowForwardedTraffic: true |
| Hub ↔ Spoke4 (10.23.0.0/16) | 双方向 | allowForwardedTraffic: true |

---

## 4. Spoke1: Rehost (`rg-spoke1`) — ~$107/月

オンプレ VM をそのまま Azure VM に移行 (Lift & Shift)。

### vm-spoke1-web — Web サーバー

| 項目 | スペック |
|---|---|
| **VM サイズ** | Standard_B2s (2 vCPU / 4 GB RAM) |
| **OS** | Windows Server 2022 Datacenter Azure Edition |
| **OS ディスク** | **Premium_LRS** (P10, ~128 GB) |
| **データディスク** | なし |
| **NIC** | nic-vm-spoke1-web × 1 |
| **IP アドレス** | 動的 (snet-web: 10.20.1.0/24) |
| **月額** | ~$50 (VM) + ~$10 (Disk) |

### vm-spoke1-sql — SQL サーバー

| 項目 | スペック |
|---|---|
| **VM サイズ** | Standard_B2ms (2 vCPU / 8 GB RAM) |
| **OS** | SQL Server 2022 Developer on Windows Server 2022 |
| **OS ディスク** | **Premium_LRS** (P10, ~128 GB) |
| **データディスク** | なし |
| **NIC** | nic-vm-spoke1-sql × 1 |
| **IP アドレス** | 動的 (snet-db: 10.20.2.0/24) |
| **月額** | ~$57 (VM) + ~$10 (Disk) |

### オンプレ → Spoke1 のスペック変化

| 項目 | オンプレ (D2s_v3) | Spoke1 Web (B2s) | Spoke1 SQL (B2ms) |
|---|---|---|---|
| **vCPU** | 2 | 2 | 2 |
| **メモリ** | 8 GB | **4 GB** ↓ | 8 GB |
| **ディスク種別** | StandardSSD | **Premium SSD** ↑ | **Premium SSD** ↑ |
| **データディスク** | 128 GB (SQL のみ) | なし | なし |
| **IP** | 静的 | 動的 | 動的 |
| **バースト** | 不可 | **可能** | **可能** |

---

## 5. Spoke2: DB PaaS 化 (`rg-spoke2`) — ~$60/月

Web サーバーは VM、データベースは Azure SQL Database に移行。

### vm-spoke2-web — Web サーバー

| 項目 | スペック |
|---|---|
| **VM サイズ** | Standard_B2s (2 vCPU / 4 GB RAM) |
| **OS** | Windows Server 2022 Datacenter Azure Edition |
| **OS ディスク** | Premium_LRS (~128 GB) |
| **NIC** | nic-vm-spoke2-web × 1 |
| **IP アドレス** | 動的 (snet-web: 10.21.1.0/24) |
| **月額** | ~$50 (VM) + ~$10 (Disk) |

### sqldb-spoke2 — Azure SQL Database

| 項目 | スペック |
|---|---|
| **サーバー名** | sql-spoke2 |
| **データベース名** | sqldb-spoke2 |
| **SKU** | Basic (5 DTU) |
| **最大サイズ** | 2 GB |
| **パブリックアクセス** | **無効** |
| **接続方式** | Private Endpoint (pep-spoke2-sql) |
| **PE サブネット** | snet-pep (10.21.2.0/24) |
| **DNS** | privatelink.database.windows.net |
| **月額** | ~$5 (SQL) + ~$7 (PE) |

---

## 6. Spoke3: コンテナ化 (`rg-spoke3`) — ~$10/月

アプリケーションをコンテナ化し、Azure Container Apps で実行。

### crspoke3 — Azure Container Registry

| 項目 | スペック |
|---|---|
| **SKU** | Basic |
| **ストレージ容量** | 10 GB |
| **Webhook 数** | 2 |
| **Geo レプリケーション** | 不可 |
| **Admin User** | 有効 |
| **月額** | ~$5 |

### cae-spoke3 — Container Apps Environment

| 項目 | スペック |
|---|---|
| **プラン** | Consumption (従量課金) |
| **VNet 統合** | snet-aca (10.22.0.0/23) |
| **内部/外部** | Internal |
| **vCPU 無料枠** | 月 180,000 vCPU 秒 |
| **メモリ無料枠** | 月 360,000 GiB 秒 |
| **月額** | ~$0 (無料枠内) |

### sqldb-spoke3 — Azure SQL Database

| 項目 | スペック |
|---|---|
| **サーバー名** | sql-spoke3 |
| **データベース名** | sqldb-spoke3 |
| **SKU** | Basic (5 DTU) |
| **最大サイズ** | 2 GB |
| **パブリックアクセス** | **無効** |
| **接続方式** | Private Endpoint (pep-spoke3-sql) |
| **PE サブネット** | snet-pep (10.22.3.0/24) |
| **月額** | ~$5 (SQL) + ~$7 (PE) |

---

## 7. Spoke4: フル PaaS 化 (`rg-spoke4`) — ~$18/月

アプリケーションと DB の両方を完全 PaaS 化。

### asp-spoke4 / app-spoke4 — App Service

| 項目 | スペック |
|---|---|
| **App Service Plan** | asp-spoke4 |
| **SKU** | B1 (Basic) |
| **vCPU** | 1 |
| **メモリ** | 1.75 GB |
| **ストレージ** | 10 GB |
| **ランタイム** | .NET 8.0 |
| **Always On** | 有効 |
| **VNet 統合** | snet-appservice (10.23.1.0/24) |
| **カスタムドメイン** | なし (app-spoke4.azurewebsites.net) |
| **月額** | ~$13 |

### sqldb-spoke4 — Azure SQL Database

| 項目 | スペック |
|---|---|
| **サーバー名** | sql-spoke4 |
| **データベース名** | sqldb-spoke4 |
| **SKU** | Basic (5 DTU) |
| **最大サイズ** | 2 GB |
| **パブリックアクセス** | **無効** |
| **接続方式** | Private Endpoint (pep-spoke4-sql) |
| **PE サブネット** | snet-pep (10.23.2.0/24) |
| **月額** | ~$5 (SQL) + ~$7 (PE) |

---

## 移行パターン別コスト比較

4 つの移行パターンを同一ワークロード（Web + DB）で比較します。

| 項目 | Spoke1: Rehost | Spoke2: DB PaaS | Spoke3: Container | Spoke4: Full PaaS |
|---|---:|---:|---:|---:|
| **月額** | ~$107 | ~$60 | ~$10 | ~$18 |
| **Web vCPU** | 2 (VM) | 2 (VM) | 従量課金 | 1 (App Service) |
| **Web メモリ** | 4 GB | 4 GB | 従量課金 | 1.75 GB |
| **DB** | VM (SQL 2022) | Azure SQL 5DTU | Azure SQL 5DTU | Azure SQL 5DTU |
| **DB ストレージ** | ~128 GB | 2 GB | 2 GB | 2 GB |
| **スケーリング** | 手動 | 手動 | **自動** | 手動 |
| **OS 管理** | **必要** | Web のみ必要 | **不要** | **不要** |
| **パッチ管理** | **必要** | Web のみ必要 | **不要** | **不要** |

---

## ディスク スペック一覧

| ディスクタイプ | IOPS | スループット | 用途 |
|---|---:|---:|---|
| **StandardSSD_LRS** (E10, 128 GB) | 500 | 60 MB/s | オンプレ VM |
| **Premium_LRS** (P10, 128 GB) | 500 | 100 MB/s | Spoke VM |

---

## コスト削減のヒント

### ハンズオン中の節約

| 方法 | 削減額/月 | 備考 |
|---|---:|---|
| **不使用時に VM を停止**（割り当て解除） | ~$568 | ディスク + 常時課金リソースのみ残る |
| **Bastion を一時デプロイ** | ~$278 | 接続時だけデプロイ → 終わったら削除 |
| **VPN Gateway を不要時に削除** | ~$365 | 再作成に 30〜45 分 |
| **Firewall を不要時に削除** | ~$219 | Hub ルーティングに影響あり |
| **全部削除して必要時に再デプロイ** | **~$1,434** | 最もコスト効率的 |

### 稼働時間ベースの概算

| 利用パターン | 概算コスト | 備考 |
|---|---:|---|
| 1 日 (8 時間) | ~$16 (~¥2,400) | ハンズオン当日のみ |
| 週末 2 日 (16 時間) | ~$32 (~¥4,800) | 週末ハンズオン |
| 1 週間 (常時起動) | ~$359 (~¥53,800) | 開発検証用途 |
| 1 か月 (常時起動) | ~$1,434 (~¥215,000) | 全リソース起動 |

---

## 参考

- [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)
- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
- [VM サイズ: Dsv3 シリーズ](https://learn.microsoft.com/azure/virtual-machines/dv3-dsv3-series)
- [VM サイズ: Bs シリーズ](https://learn.microsoft.com/azure/virtual-machines/sizes-b-series-burstable)
- [Azure SQL Database 価格](https://learn.microsoft.com/azure/azure-sql/database/purchasing-models?view=azuresql)
- [Azure Firewall 価格](https://azure.microsoft.com/pricing/details/azure-firewall/)
- [Azure Bastion 価格](https://azure.microsoft.com/pricing/details/azure-bastion/)
- [Managed Disks 価格](https://azure.microsoft.com/pricing/details/managed-disks/)
