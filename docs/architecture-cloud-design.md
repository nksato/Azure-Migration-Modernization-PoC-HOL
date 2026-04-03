# クラウド移行 HOL - アーキテクチャ設計書

## 1. 目的

本ドキュメントは、`DC01` / `DB01` / `APP01` で構成された疑似オンプレ環境を Azure に移行・モダナイズするための**移行先クラウド基盤**を定義します。

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

| VNet | CIDR | 役割 |
|---|---|---|
| `OnPrem VNet` | `10.0.0.0/16` | 移行元（疑似オンプレ） |
| `Hub VNet` | `10.10.0.0/16` | 共通サービス・管理基盤 |
| `Spoke1 VNet` | `10.20.0.0/16` | Rehost 用 |
| `Spoke2 VNet` | `10.21.0.0/16` | DB PaaS 化用 |
| `Spoke3 VNet` | `10.22.0.0/16` | コンテナ化用 |
| `Spoke4 VNet` | `10.23.0.0/16` | フル PaaS 化用 |

### Hub VNet の主な役割

| サービス | 役割 |
|---|---|
| Azure Firewall | Spoke 間・外向き通信の制御 |
| VPN Gateway | OnPrem VNet との接続 |
| Azure Bastion | 管理用アクセス |
| Log Analytics | 監視データ集約 |
| Azure Policy | ガバナンス |
| Defender for Cloud | セキュリティ評価 |
| Azure Migrate Project | 移行評価・計画 |

---

## 3. 設計原則

### 3.1 移行元との整合性

本 HOL では、移行元システムを以下として統一します。

| ホスト | 役割 |
|---|---|
| `DC01` | Active Directory / DNS |
| `DB01` | SQL Server |
| `APP01` | IIS + Parts Unlimited |

> 本ドキュメントでは、`docs/handson` の移行元環境説明と整合するように、`APP01` / `DB01` / `DC01` 基準で記載を統一しています。

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
- `infra/cloud/main.bicep`（互換性維持用ラッパー）
- `infra/cloud/cloud/main.bicep`（クラウド側 Hub / Spoke 基盤）
- `infra/cloud/cloud/azuredeploy.json`
- `infra/cloud/modules/**`

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
