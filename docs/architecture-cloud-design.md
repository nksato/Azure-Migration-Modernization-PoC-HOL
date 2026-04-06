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

### 設計原則

- **移行元との整合性**: 移行元は DC01 / DB01 / APP01 で統一
- **段階的モダナイズ**: Spoke1 (最小変更) → Spoke4 (フル PaaS) へ段階的に
- **管理の一元化**: Azure Arc で移行前サーバーも Azure 管理面に統合

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

---

## 3. リソース構成

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

### Spoke ごとの役割

| Spoke | パターン | 概要 |
|---|---|---|
| Spoke1 | Rehost | `APP01` / `DB01` をそのまま Azure VM へ移行。最短でのクラウド移行 |
| Spoke2 | DB PaaS 化 | Web は VM のまま維持、DB を Azure SQL Database に移行 |
| Spoke3 | コンテナ化 | Web を .NET 8 + Docker 化し Container Apps に配置。DB は Azure SQL |
| Spoke4 | フル PaaS 化 | Web を .NET 8 + App Service へ集約。DB は Azure SQL。運用負荷最小 |

---

## 4. ネットワーク設計

### VNet ピアリング

Hub ↔ Spoke1〜4 の間で VNet ピアリングを設定します。VPN Gateway デプロイ後に Gateway Transit を有効化します。

| 設定 | Hub → Spoke | Spoke → Hub |
|---|---|---|
| `allowGatewayTransit` | `true` | — |
| `useRemoteGateways` | — | `true` |
| `allowForwardedTraffic` | `true` | `true` |

これにより、Spoke の VM はオンプレ VNet と VPN 経由で通信できます。

### Azure Firewall ルール

`afwp-hub` (Firewall Policy) に以下のルールコレクションを定義しています。

**ネットワークルール (優先度: 200)**

| ルール名 | ソース | 宛先 | プロトコル |
|---|---|---|---|
| `OnPrem-to-Spokes` | `10.0.0.0/16` | `10.20-23.0.0/16` | Any |
| `Spokes-to-OnPrem` | `10.20-23.0.0/16` | `10.0.0.0/16` | Any |
| `Spoke-to-Spoke` | `10.20-23.0.0/16` | `10.20-23.0.0/16` | Any |

**アプリケーションルール (優先度: 300)**

| ルール名 | ソース | 宛先 FQDN | ポート |
|---|---|---|---|
| `Allow-WindowsUpdate` | `*` | `*.windowsupdate.com` 等 | HTTPS:443 |
| `Allow-AzureServices` | `*` | `*.azure.com`, `*.microsoft.com` 等 | HTTPS:443 |
| `Allow-ArcEndpoints` | `10.0.0.0/16` | Arc 固有エンドポイント | HTTPS:443 |

### ルートテーブル

`rt-spokes-to-fw` を全 Spoke サブネットに関連付け、トラフィックを Firewall 経由に制御します。

| ルート名 | アドレスプレフィックス | ネクストホップ |
|---|---|---|
| `default-to-firewall` | `0.0.0.0/0` | Firewall Private IP |
| `onprem-to-firewall` | `10.0.0.0/16` | Firewall Private IP |

---

## 5. ネットワーク接続と DNS

### VPN Gateway (S2S 接続)

`infra/network/main.bicep` で、疑似オンプレ (`vnet-onprem`) と Hub (`vnet-hub`) の間に Site-to-Site VPN 接続を確立します。

| リソース名 | リソースグループ | 役割 |
|---|---|---|
| `vpngw-hub` | rg-hub | Hub 側 VPN Gateway (AVM, VpnGw1AZ) |
| `vgw-onprem` | rg-onprem | オンプレ側 VPN Gateway (VpnGw1AZ) |
| `lgw-hub` | rg-onprem | Local Network Gateway (Hub 側を参照) |
| `lgw-onprem` | rg-hub | Local Network Gateway (オンプレ側を参照) |
| `cn-onprem-to-hub` | rg-onprem | S2S 接続 (オンプレ → Hub) |
| `cn-hub-to-onprem` | rg-hub | S2S 接続 (Hub → オンプレ) |

- プロトコル: IKEv2
- 接続種別: IPsec (共有キー認証)

### クラウド → オンプレ (DNS Forwarding Ruleset)

`dnsrs-hub` により、クラウドからオンプレの AD ドメイン名を解決します。

| 設定 | 値 |
|---|---|
| ルールセット名 | `dnsrs-hub` |
| 転送ルール | `lab.local.` → `10.0.1.4` (DC01) : port 53 |
| リンク先 VNet | `vnet-hub` |
| Outbound Endpoint | `dnspr-hub/outbound` (`snet-dns-outbound`) |

Hub VNet の DNS サーバー設定は Azure 既定のため、Hub にリンクされた Forwarding Ruleset が自動的に適用されます。Spoke は VNet ピアリング経由で Hub の DNS Resolver を利用します。

### オンプレ → クラウド (条件付きフォワーダー)

DC01 に条件付きフォワーダーを手動で追加し、Private Endpoint の名前解決を可能にします。

| 設定 | 値 |
|---|---|
| 対象ゾーン | `privatelink.database.windows.net` |
| 転送先 | DNS Private Resolver Inbound IP (`snet-dns-inbound` 内) |
| 設定方法 | `infra/network/Setup-HybridDns.ps1` または手動 |

### Private DNS Zone

`privatelink.database.windows.net` を Hub VNet および Spoke2〜4 VNet にリンクし、Azure SQL の Private Endpoint 名前解決を提供します。

| リンク先 VNet | 用途 |
|---|---|
| `vnet-hub` | Hub 経由での解決 |
| `vnet-spoke2` | DB PaaS 化 — Azure SQL Private Endpoint |
| `vnet-spoke3` | コンテナ化 — Azure SQL Private Endpoint |
| `vnet-spoke4` | フル PaaS 化 — Azure SQL Private Endpoint |

---

## 6. デプロイ

初期環境およびクラウド側の Bicep / ARM 参照元は以下です。

| テンプレート | 役割 |
|---|---|
| `infra/main.bicep` | 初期環境の一括セットアップ用エントリポイント |
| `infra/cloud/main.bicep` | クラウド側 Hub / Spoke 基盤 |
| `infra/network/main.bicep` | VPN Gateway 配置・S2S 接続・ピアリング Gateway Transit |
| `infra/cloud/modules/network/firewall.bicep` | Azure Firewall + Policy + ルール |
| `infra/cloud/modules/network/dns-forwarding-ruleset.bicep` | DNS Forwarding Ruleset |
| `infra/cloud/modules/governance/dashboard.bicep` | Portal Dashboard |
| `infra/cloud/azuredeploy.json` | ARM テンプレート (main.bicep のコンパイル済み) |

Spoke ごとの追加リソースは以下を利用します。

| テンプレート | Spoke | リソース |
|---|---|---|
| `infra/cloud/modules/spoke-resources/spoke1-rehost.bicep` | Spoke1 | VM × 2 (Web + SQL) |
| `infra/cloud/modules/spoke-resources/spoke2-db-paas.bicep` | Spoke2 | VM + Azure SQL + Private Endpoint |
| `infra/cloud/modules/spoke-resources/spoke3-container.bicep` | Spoke3 | ACR + Container Apps + Azure SQL |
| `infra/cloud/modules/spoke-resources/spoke4-full-paas.bicep` | Spoke4 | App Service (B1/.NET 8) + Azure SQL |

> **注意:** `infra/cloud/modules/migration/migrate-project.bicep` は存在しますが、現在 `cloud/main.bicep` からは呼び出されていません。Azure Migrate プロジェクトは手動で作成します。

---

## 7. 関連ドキュメント

- 移行元（オンプレ設計）: [`./architecture-onprem-design.md`](./architecture-onprem-design.md)
- 移行元（オンプレ図解）: [`./architecture-onprem-diagrams.md`](./architecture-onprem-diagrams.md)
- クラウド図解: [`./architecture-cloud-diagrams.md`](./architecture-cloud-diagrams.md)
- クラウド手順: [`./handson/00d-cloud-deploy.md`](./handson/00d-cloud-deploy.md)
- VPN 接続構成: [`./handson/00e-cloud-vpn-connect.md`](./handson/00e-cloud-vpn-connect.md)
- ハイブリッド DNS: [`./handson/00f-cloud-hybrid-dns.md`](./handson/00f-cloud-hybrid-dns.md)
- 検証スクリプト: [`./architecture-verify-scripts.md`](./architecture-verify-scripts.md)
