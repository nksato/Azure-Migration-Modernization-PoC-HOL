# Azure Migration & Modernization HOL ドキュメント

この `docs` フォルダは、**移行元（疑似オンプレ）**と**移行先（クラウド）**を**同じレベル**で整理した正式ドキュメント群です。

---

## 📚 ドキュメント構成

### 0. 初期環境セットアップ

| ファイル | 内容 |
|---|---|
| [`handson/00-initial-setup.md`](./handson/00-initial-setup.md) | 初期環境を一括または 3 ステップで構築する導入手順 |

### 1. 移行元: 疑似オンプレ環境

| ファイル | 内容 |
|---|---|
| [`architecture-onprem-design.md`](./architecture-onprem-design.md) | 疑似オンプレ環境の設計方針・構成要素・テンプレート差分 |
| [`architecture-onprem-diagrams.md`](./architecture-onprem-diagrams.md) | Mermaid による移行元構成図・セットアップフロー |
| [`handson/00a-onprem-deploy.md`](./handson/00a-onprem-deploy.md) | 移行元インフラのデプロイ手順 |
| [`handson/00b-onprem-parts-unlimited.md`](./handson/00b-onprem-parts-unlimited.md) | `DB01` / `APP01` のセットアップ手順 |
| [`handson/00c-onprem-verification.md`](./handson/00c-onprem-verification.md) | 動作確認・疎通確認手順 |

### 2. 移行先: クラウド環境

| ファイル | 内容 |
|---|---|
| [`architecture-cloud-design.md`](./architecture-cloud-design.md) | Hub & Spoke / 移行パターン設計 |
| [`architecture-cloud-diagrams.md`](./architecture-cloud-diagrams.md) | クラウド構成図・移行フロー図 |
| [`handson/00d-cloud-deploy.md`](./handson/00d-cloud-deploy.md) | クラウド基盤のデプロイ |
| [`handson/00e-cloud-vpn-connect.md`](./handson/00e-cloud-vpn-connect.md) | クラウド VPN 接続の構成 |

### 3. クラウド移行 HOL

| ファイル | 内容 |
|---|---|
| [`handson/01-cloud-explore-onprem.md`](./handson/01-cloud-explore-onprem.md) | 移行元環境の確認 |
| [`handson/02-cloud-arc-onboard.md`](./handson/02-cloud-arc-onboard.md) | Azure Arc 登録 |
| [`handson/03-cloud-hybrid-mgmt.md`](./handson/03-cloud-hybrid-mgmt.md) | ハイブリッド管理 |
| [`handson/04-cloud-assessment.md`](./handson/04-cloud-assessment.md) | 移行アセスメント |
| [`handson/05a-cloud-rehost.md`](./handson/05a-cloud-rehost.md) | Rehost |
| [`handson/05b-cloud-db-paas.md`](./handson/05b-cloud-db-paas.md) | DB PaaS 化 |
| [`handson/05c-cloud-containerize.md`](./handson/05c-cloud-containerize.md) | コンテナ化 |
| [`handson/05d-cloud-full-paas.md`](./handson/05d-cloud-full-paas.md) | フル PaaS 化 |
| [`handson/06-cloud-compare.md`](./handson/06-cloud-compare.md) | 比較・まとめ |

---

## 🎯 このドキュメント群の役割

- `DC01` / `DB01` / `APP01` で構成された**移行元**を準備する
- Hub & Spoke を中心にした**移行先クラウド基盤**を整理する
- Rehost / DB PaaS 化 / コンテナ化 / フル PaaS 化を比較できるようにする

---

## 🚀 推奨の読み順

0. **初期環境をセットアップ**
   - [`handson/00-initial-setup.md`](./handson/00-initial-setup.md)
1. **移行元を準備**
   - [`handson/00a-onprem-deploy.md`](./handson/00a-onprem-deploy.md)
   - [`handson/00b-onprem-parts-unlimited.md`](./handson/00b-onprem-parts-unlimited.md)
   - [`handson/00c-onprem-verification.md`](./handson/00c-onprem-verification.md)
2. **クラウド環境を準備**
   - [`handson/00d-cloud-deploy.md`](./handson/00d-cloud-deploy.md)
   - [`handson/00e-cloud-vpn-connect.md`](./handson/00e-cloud-vpn-connect.md)
3. **クラウド移行 HOL を開始**
   - [`handson/01-cloud-explore-onprem.md`](./handson/01-cloud-explore-onprem.md)
   - [`handson/02-cloud-arc-onboard.md`](./handson/02-cloud-arc-onboard.md)
   - [`handson/03-cloud-hybrid-mgmt.md`](./handson/03-cloud-hybrid-mgmt.md)
   - [`handson/04-cloud-assessment.md`](./handson/04-cloud-assessment.md)
   - [`handson/05a-cloud-rehost.md`](./handson/05a-cloud-rehost.md)
   - [`handson/05b-cloud-db-paas.md`](./handson/05b-cloud-db-paas.md)
   - [`handson/05c-cloud-containerize.md`](./handson/05c-cloud-containerize.md)
   - [`handson/05d-cloud-full-paas.md`](./handson/05d-cloud-full-paas.md)
   - [`handson/06-cloud-compare.md`](./handson/06-cloud-compare.md)

---

## 🔗 関連ドキュメント

- [`../README.md`](../README.md)
- [`./architecture-onprem-design.md`](./architecture-onprem-design.md)
- [`./architecture-cloud-design.md`](./architecture-cloud-design.md)
