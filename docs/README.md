# Azure Migration & Modernization HOL ドキュメント

この `docs` フォルダは、**移行元（疑似オンプレ）**と**移行先（クラウド）**を**同じレベル**で整理した正式ドキュメント群です。

---

## 📚 ドキュメント構成

### 1. 移行元: 疑似オンプレ環境

| ファイル | 内容 |
|---|---|
| [`architecture-onprem-design.md`](./architecture-onprem-design.md) | 疑似オンプレ環境の設計方針・構成要素・テンプレート差分 |
| [`architecture-onprem-diagrams.md`](./architecture-onprem-diagrams.md) | Mermaid による移行元構成図・セットアップフロー |
| [`handson/01-onprem-deploy.md`](./handson/01-onprem-deploy.md) | 移行元インフラのデプロイ手順 |
| [`handson/02-onprem-parts-unlimited.md`](./handson/02-onprem-parts-unlimited.md) | `DB01` / `APP01` のセットアップ手順 |
| [`handson/03-onprem-verification.md`](./handson/03-onprem-verification.md) | 動作確認・疎通確認手順 |

### 2. 移行先: クラウド移行 HOL

| ファイル | 内容 |
|---|---|
| [`architecture-cloud-design.md`](./architecture-cloud-design.md) | Hub & Spoke / 移行パターン設計 |
| [`architecture-cloud-diagrams.md`](./architecture-cloud-diagrams.md) | クラウド構成図・移行フロー図 |
| [`handson/04-cloud-deploy.md`](./handson/04-cloud-deploy.md) | クラウド基盤のデプロイ |
| [`handson/05-cloud-explore-onprem.md`](./handson/05-cloud-explore-onprem.md) | 移行元環境の確認 |
| [`handson/06-cloud-arc-onboard.md`](./handson/06-cloud-arc-onboard.md) | Azure Arc 登録 |
| [`handson/07-cloud-hybrid-mgmt.md`](./handson/07-cloud-hybrid-mgmt.md) | ハイブリッド管理 |
| [`handson/08-cloud-assessment.md`](./handson/08-cloud-assessment.md) | 移行アセスメント |
| [`handson/09-cloud-rehost.md`](./handson/09-cloud-rehost.md) ～ [`handson/12-cloud-full-paas.md`](./handson/12-cloud-full-paas.md) | 4 つの移行パターン |
| [`handson/13-cloud-compare.md`](./handson/13-cloud-compare.md) | 比較・まとめ |

---

## 🎯 このドキュメント群の役割

- `DC01` / `DB01` / `APP01` で構成された**移行元**を準備する
- Hub & Spoke を中心にした**移行先クラウド基盤**を整理する
- Rehost / DB PaaS 化 / コンテナ化 / フル PaaS 化を比較できるようにする

---

## 🚀 推奨の読み順

1. **移行元を準備**
   - [`handson/01-onprem-deploy.md`](./handson/01-onprem-deploy.md)
   - [`handson/02-onprem-parts-unlimited.md`](./handson/02-onprem-parts-unlimited.md)
   - [`handson/03-onprem-verification.md`](./handson/03-onprem-verification.md)
2. **クラウド移行 HOL を開始**
   - [`handson/04-cloud-deploy.md`](./handson/04-cloud-deploy.md)
   - [`handson/05-cloud-explore-onprem.md`](./handson/05-cloud-explore-onprem.md)
   - [`handson/06-cloud-arc-onboard.md`](./handson/06-cloud-arc-onboard.md)
   - [`handson/07-cloud-hybrid-mgmt.md`](./handson/07-cloud-hybrid-mgmt.md)
   - [`handson/08-cloud-assessment.md`](./handson/08-cloud-assessment.md)
   - [`handson/09-cloud-rehost.md`](./handson/09-cloud-rehost.md) ～ [`handson/12-cloud-full-paas.md`](./handson/12-cloud-full-paas.md)
   - [`handson/13-cloud-compare.md`](./handson/13-cloud-compare.md)

---

## 🔗 参照元

- `tmp/onprem/**`
- `tmp/cloud/**`

> ルート配下の `docs` は、`tmp` 内の参考ドキュメントをもとに、オンプレ/クラウドを同列の構成で再整理した正式版です。
