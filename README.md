# Azure Migration & Modernization PoC ハンズオンラボ

オンプレミス環境を模した Windows Server、SQL Server、.NET Framework ワークロードの Web 3 層アプリケーションを題材に、**Azure への移行**と**モダナイゼーション**を段階的に体験できるハンズオンラボです。  
移行対象アプリには Microsoft 公式サンプルの **[Parts Unlimited](https://github.com/Microsoft/PartsUnlimitedE2E)**（ASP.NET MVC / .NET Framework）を使用します。  
疑似オンプレ環境（`DC01` / `DB01` / `APP01`）を準備し、Azure Arc・Azure Migrate・各種 PaaS を使いながら、複数の移行パターンを比較できます。

---

## 概要

このラボでは、以下の一連の流れを体験できます。

- 疑似オンプレ環境の構築とアプリ動作確認
- Azure Arc によるハイブリッド管理
- Azure Migrate によるアセスメント
- 4 つの移行/モダナイズ パターンの比較
  - Rehost
  - DB PaaS 化
  - コンテナ化
  - フル PaaS 化

---

## 対象者

- Azure への移行を提案・設計するパートナー/SE
- オンプレミス ワークロードのクラウド移行を検討するお客様
- IaaS から PaaS/コンテナまでの比較検討をしたい技術者
- Azure Arc / Azure Migrate を実際の流れに沿って学びたい方

---

## このラボで学べること

| テーマ | 学べる内容 |
|---|---|
| 移行元の理解 | 既存アプリ/DB/AD を含む典型的な構成の把握 |
| ハイブリッド管理 | Azure Arc / Policy / Monitor / Defender の活用 |
| アセスメント | Azure Migrate による移行前評価 |
| 移行パターン比較 | VM 維持、DB のみ PaaS、コンテナ化、フル PaaS の違い |
| モダナイゼーション | .NET アプリの段階的な改善アプローチ |

---

## ラボ シナリオ

### フェーズ 1: 初期環境構築

まずは、ハンズオン全体で共通利用する移行元・移行先の環境を準備します。

| Step | ドキュメント | 内容 |
|---|---|---|
| 1.0 | [`docs/handson/1.0-prerequisites.md`](./docs/handson/1.0-prerequisites.md) | 作業環境の準備（Azure CLI / Git / クローン） |
| 1.1 | [`docs/handson/1.1-initial-setup.md`](./docs/handson/1.1-initial-setup.md) | 初期環境を一括または段階的にセットアップ |
| 1.2 | [`docs/handson/1.2-onprem-deploy.md`](./docs/handson/1.2-onprem-deploy.md) | 疑似オンプレ環境をデプロイ |
| 1.3 | [`docs/handson/1.3-onprem-parts-unlimited.md`](./docs/handson/1.3-onprem-parts-unlimited.md) | `DB01` / `APP01` に Parts Unlimited をセットアップ |
| 1.4 | [`docs/handson/1.4-onprem-verification.md`](./docs/handson/1.4-onprem-verification.md) | アプリと通信を確認 |
| 1.5 | [`docs/handson/1.5-cloud-deploy.md`](./docs/handson/1.5-cloud-deploy.md) | 移行先クラウド基盤をデプロイ |
| 1.6 | [`docs/handson/1.6-cloud-vpn-connect.md`](./docs/handson/1.6-cloud-vpn-connect.md) | クラウド VPN 接続を構成 |
| 1.7 | [`docs/handson/1.7-cloud-hybrid-dns.md`](./docs/handson/1.7-cloud-hybrid-dns.md) | ハイブリッド DNS を設定 |

> ワンクリックで初期環境を作成したい場合は、[`docs/handson/1.1-initial-setup.md`](./docs/handson/1.1-initial-setup.md) の **Deploy to Azure** ボタンを利用できます。

### フェーズ 2: クラウド移行 HOL

初期環境の準備後、以下の手順で移行評価とモダナイズ比較を進めます。

| Step | ドキュメント | 内容 |
|---|---|---|
| 2.1 | [`docs/handson/2.1-cloud-explore-onprem.md`](./docs/handson/2.1-cloud-explore-onprem.md) | 移行元環境の現状確認 |
| 2.2 | [`docs/handson/2.2-cloud-arc-onboard.md`](./docs/handson/2.2-cloud-arc-onboard.md) | Azure Arc 登録 |
| 2.3 | [`docs/handson/2.3-cloud-hybrid-mgmt.md`](./docs/handson/2.3-cloud-hybrid-mgmt.md) | ハイブリッド管理を体験 |
| 2.4 | [`docs/handson/2.4-cloud-assessment.md`](./docs/handson/2.4-cloud-assessment.md) | Azure Migrate で評価 |
| 2.5.1 | [`docs/handson/2.5.1-cloud-rehost.md`](./docs/handson/2.5.1-cloud-rehost.md) | Rehost（Lift & Shift）を実施 |
| 2.5.2 | [`docs/handson/2.5.2-cloud-db-paas.md`](./docs/handson/2.5.2-cloud-db-paas.md) | DB PaaS 化を実施 |
| 2.5.3 | [`docs/handson/2.5.3-cloud-containerize.md`](./docs/handson/2.5.3-cloud-containerize.md) | コンテナ化を実施 |
| 2.5.4 | [`docs/handson/2.5.4-cloud-full-paas.md`](./docs/handson/2.5.4-cloud-full-paas.md) | フル PaaS 化を実施 |
| 2.6 | [`docs/handson/2.6-cloud-compare.md`](./docs/handson/2.6-cloud-compare.md) | 結果の比較とまとめ |
| 2.7 | [`docs/handson/2.7-cloud-cleanup.md`](./docs/handson/2.7-cloud-cleanup.md) | リソースのクリーンアップ |

---

## アーキテクチャ概要

- **移行元**: `DC01` / `DB01` / `APP01` による疑似オンプレ 3 層構成
- **移行先**: Hub & Spoke をベースにした Azure 環境
- **比較対象**:
  - Spoke1: Rehost
  - Spoke2: DB PaaS 化
  - Spoke3: コンテナ化
  - Spoke4: フル PaaS 化

詳細は以下を参照してください。

- [`docs/architecture/architecture-onprem-design.md`](./docs/architecture/architecture-onprem-design.md)
- [`docs/architecture/architecture-onprem-diagrams.md`](./docs/architecture/architecture-onprem-diagrams.md)
- [`docs/architecture/architecture-cloud-design.md`](./docs/architecture/architecture-cloud-design.md)
- [`docs/architecture/architecture-cloud-diagrams.md`](./docs/architecture/architecture-cloud-diagrams.md)

---

## 前提条件

- Azure サブスクリプション
- Azure リソース作成権限
- PowerShell / Azure CLI の基本操作
- 必要に応じて GitHub Copilot ライセンス（モダナイズ系ステップで活用）

---

## はじめ方

1. [`docs/README.md`](./docs/README.md) で全体構成を確認
2. [`docs/handson/1.1-initial-setup.md`](./docs/handson/1.1-initial-setup.md) から初期環境を準備
3. [`docs/handson/1.2-onprem-deploy.md`](./docs/handson/1.2-onprem-deploy.md) 以降を順に実施
4. `Step 02 ～ 06` で Azure Arc / Azure Migrate / 各移行パターンを比較

---

## リポジトリ内の位置づけ

- `docs/` : ハンズオン ドキュメント
- `infra/` : ハンズオンで利用する Bicep / ARM / パラメータ / PowerShell 資産
