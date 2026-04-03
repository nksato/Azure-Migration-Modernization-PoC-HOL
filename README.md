# Azure Migration & Modernization PoC ハンズオンラボ

オンプレミス環境を模した Windows ベースの 3 層アプリケーションを題材に、**Azure への移行**と**モダナイゼーション**を段階的に体験できるハンズオンラボです。  
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

| Step | ドキュメント | 内容 |
|---|---|---|
| 00 | [`docs/handson/00-initial-setup.md`](./docs/handson/00-initial-setup.md) | 初期環境を一括または段階的にセットアップ |
| 01 | [`docs/handson/01-onprem-deploy.md`](./docs/handson/01-onprem-deploy.md) | 疑似オンプレ環境をデプロイ |
| 02 | [`docs/handson/02-onprem-parts-unlimited.md`](./docs/handson/02-onprem-parts-unlimited.md) | `DB01` / `APP01` に Parts Unlimited をセットアップ |
| 03 | [`docs/handson/03-onprem-verification.md`](./docs/handson/03-onprem-verification.md) | アプリと通信を確認 |
| 04 | [`docs/handson/04-cloud-deploy.md`](./docs/handson/04-cloud-deploy.md) | 移行先クラウド基盤をデプロイ |
| 05 | [`docs/handson/05-cloud-explore-onprem.md`](./docs/handson/05-cloud-explore-onprem.md) | 移行元環境の現状確認 |
| 06 | [`docs/handson/06-cloud-arc-onboard.md`](./docs/handson/06-cloud-arc-onboard.md) | Azure Arc へ接続 |
| 07 | [`docs/handson/07-cloud-hybrid-mgmt.md`](./docs/handson/07-cloud-hybrid-mgmt.md) | ハイブリッド管理を体験 |
| 08 | [`docs/handson/08-cloud-assessment.md`](./docs/handson/08-cloud-assessment.md) | Azure Migrate で評価 |
| 09-12 | [`docs/handson/09-cloud-rehost.md`](./docs/handson/09-cloud-rehost.md) ～ [`docs/handson/12-cloud-full-paas.md`](./docs/handson/12-cloud-full-paas.md) | 4 つの移行パターンを比較 |
| 13 | [`docs/handson/13-cloud-compare.md`](./docs/handson/13-cloud-compare.md) | 結果の比較とまとめ |

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

- [`docs/architecture-onprem-design.md`](./docs/architecture-onprem-design.md)
- [`docs/architecture-onprem-diagrams.md`](./docs/architecture-onprem-diagrams.md)
- [`docs/architecture-cloud-design.md`](./docs/architecture-cloud-design.md)
- [`docs/architecture-cloud-diagrams.md`](./docs/architecture-cloud-diagrams.md)

---

## 前提条件

- Azure サブスクリプション
- Azure リソース作成権限
- PowerShell / Azure CLI の基本操作
- 必要に応じて GitHub Copilot ライセンス（モダナイズ系ステップで活用）

---

## はじめ方

1. [`docs/README.md`](./docs/README.md) で全体構成を確認
2. [`docs/handson/00-initial-setup.md`](./docs/handson/00-initial-setup.md) から初期環境を準備
3. [`docs/handson/01-onprem-deploy.md`](./docs/handson/01-onprem-deploy.md) 以降を順に実施
4. `Step 04` 以降で Azure Arc / Azure Migrate / 各移行パターンを比較

---

## リポジトリ内の位置づけ

- `docs/` : 正式なハンズオン ドキュメント
- `tmp/onprem/` : 移行元（疑似オンプレ）側の元資料
- `tmp/cloud/` : クラウド移行側の元資料

> 本リポジトリの `docs/` は、`tmp` 配下の参考資料をもとに再整理した、参加者向けの正式版ドキュメントです。
