# クラウド移行 HOL - アーキテクチャ設計書

## 1. 目的

`DC01` / `DB01` / `APP01` で構成された疑似オンプレ環境を Azure に移行・モダナイズするための**移行先クラウド基盤**を定義します。

この HOL では、Hub & Spoke 構成を用いて、以下の 4 つの移行パターンを比較します。

| Spoke | パターン | AP 基盤 | DB 基盤 |
|---|---|---|---|
| Spoke1 | Rehost | Azure VM | Azure VM |
| Spoke2 | DB PaaS 化 | Azure VM | Azure SQL Database |
| Spoke3 | コンテナ化 | Azure Container Apps | Azure SQL Database |
| Spoke4 | フル PaaS 化 | Azure App Service | Azure SQL Database |

---

## 2. 全体構成

### ネットワーク構成

| VNet | CIDR | リソースグループ | 役割 |
|---|---|---|---|
| `vnet-onprem` | `10.0.0.0/16` | rg-onprem | 移行元（疑似オンプレ） |
| `vnet-hub` | `10.10.0.0/16` | rg-hub | 共通サービス・管理基盤 |
| `vnet-spoke1` | `10.20.0.0/16` | rg-spoke1 | Rehost 用 |
| `vnet-spoke2` | `10.21.0.0/16` | rg-spoke2 | DB PaaS 化用 |
| `vnet-spoke3` | `10.22.0.0/16` | rg-spoke3 | コンテナ化用 |
| `vnet-spoke4` | `10.23.0.0/16` | rg-spoke4 | フル PaaS 化用 |

### Hub VNet サブネット構成

| サブネット | CIDR | 用途 |
|---|---|---|
| `AzureFirewallSubnet` | `10.10.1.0/26` | Azure Firewall |
| `AzureFirewallManagementSubnet` | `10.10.4.0/26` | Firewall 管理 (Basic SKU 必須) |
| `AzureBastionSubnet` | `10.10.2.0/26` | Azure Bastion |
| `GatewaySubnet` | `10.10.255.0/27` | VPN Gateway |
| `snet-dns-inbound` | `10.10.5.0/28` | DNS Private Resolver Inbound |
| `snet-dns-outbound` | `10.10.5.16/28` | DNS Private Resolver Outbound |

### Spoke VNet サブネット構成

| Spoke | サブネット | CIDR | 用途 |
|---|---|---|---|
| Spoke1 | `snet-web` | `10.20.1.0/24` | Web VM |
| Spoke1 | `snet-db` | `10.20.2.0/24` | SQL VM |
| Spoke2 | `snet-web` | `10.21.1.0/24` | Web VM |
| Spoke2 | `snet-pep` | `10.21.2.0/24` | Private Endpoint (Azure SQL) |
| Spoke3 | `snet-aca` | `10.22.0.0/23` | Container Apps Environment |
| Spoke3 | `snet-pep` | `10.22.3.0/24` | Private Endpoint (Azure SQL) |
| Spoke4 | `snet-appservice` | `10.23.1.0/24` | App Service VNet Integration |
| Spoke4 | `snet-pep` | `10.23.2.0/24` | Private Endpoint (Azure SQL) |

### Hub の主なリソース (rg-hub)

| リソース名 | 種別 | 役割 |
|---|---|---|
| `afw-hub` | Azure Firewall (Basic) | Spoke 間・外向き通信の制御 |
| `afwp-hub` | Firewall Policy | Firewall のルール定義 |
| `rt-spokes-to-fw` | Route Table | Spoke トラフィックを Firewall 経由に制御 |
| `vpngw-hub` | VPN Gateway (VpnGw1AZ) | オンプレ VNet との S2S 接続 |
| `bas-hub` | Azure Bastion (Basic) | 管理用 RDP アクセス |
| `law-hub` | Log Analytics Workspace | 監視データ集約 (30 日保持) |
| `dnspr-hub` | DNS Private Resolver | ハイブリッド DNS 解決 |
| `dnsrs-hub` | DNS Forwarding Ruleset | `lab.local` をオンプレ DC01 へ転送 |
| `privatelink.database.windows.net` | Private DNS Zone | Azure SQL の Private Endpoint 名前解決 |
| `dash-poc-overview` | Portal Dashboard | PoC 環境の概要ダッシュボード |

### サブスクリプションスコープの管理リソース

| リソース | 役割 |
|---|---|
| Azure Policy (計 6 ポリシー) | リージョン制限・タグ強制・パブリックアクセス監査・管理ポート監査 |
| Defender for Cloud | VM: Standard、その他: Free |

---

## 3. 設計原則

### 3.1 移行元との整合性

移行元システムは以下として統一します。

| ホスト | 役割 |
|---|---|
| `DC01` | Active Directory / DNS |
| `DB01` | SQL Server |
| `APP01` | IIS + Parts Unlimited |

### 3.2 段階的モダナイズ

- **Spoke1**: 最小変更での移行
- **Spoke2**: DB のみ先に PaaS 化
- **Spoke3**: アプリを .NET 8 + コンテナ化
- **Spoke4**: アプリを .NET 8 + App Service へ集約

### 3.3 管理の一元化

Azure Arc によって、移行前のサーバーも Azure 管理面に統合します。

---

## 4. Spoke ごとの役割

### Spoke1 - Rehost
- `APP01` をそのまま Azure VM へ移行
- `DB01` も Azure VM へ移行
- 最短でのクラウド移行を体験

### Spoke2 - DB PaaS 化
- Web は VM のまま維持
- DB を Azure SQL Database に移行
- アプリ変更は接続先中心

### Spoke3 - コンテナ化
- Web アプリを .NET 8 に変換
- Docker イメージ化して Container Apps に配置
- DB は Azure SQL を利用

### Spoke4 - フル PaaS 化
- Web アプリを .NET 8 化して App Service へ配置
- DB は Azure SQL を利用
- 運用負荷を最も下げるパターン

---

## 5. デプロイ単位

初期環境およびクラウド側の Bicep / ARM 参照元は以下です。

- `infra/main.bicep`（初期環境の一括セットアップ用エントリポイント）
- `infra/cloud/main.bicep`（クラウド側 Hub / Spoke 基盤）
- `infra/cloud/azuredeploy.json`
- `infra/cloud/modules/**`
- `infra/cloud/scripts/**`

Spoke ごとの追加リソースは以下を利用します。

- `infra/cloud/modules/spoke-resources/spoke1-rehost.bicep`
- `infra/cloud/modules/spoke-resources/spoke2-db-paas.bicep`
- `infra/cloud/modules/spoke-resources/spoke3-container.bicep`
- `infra/cloud/modules/spoke-resources/spoke4-full-paas.bicep`

---

## 6. 関連ドキュメント

- 移行元（オンプレ設計）: [`./architecture-onprem-design.md`](./architecture-onprem-design.md)
- 移行元（オンプレ図解）: [`./architecture-onprem-diagrams.md`](./architecture-onprem-diagrams.md)
- クラウド図解: [`./architecture-cloud-diagrams.md`](./architecture-cloud-diagrams.md)
- クラウド手順: [`./handson/00d-cloud-deploy.md`](./handson/00d-cloud-deploy.md)
