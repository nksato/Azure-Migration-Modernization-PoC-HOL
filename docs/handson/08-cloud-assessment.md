# 08. 移行アセスメント

このフェーズでは、Azure Migrate を用いて移行元システムの**評価・方針整理**を行います。

## 目的

- 移行元のサーバー構成を棚卸しする
- Azure VM / Azure SQL / App Service への適合性を確認する
- Spoke1～4 のどのパターンが適切か比較する

## 対象

| サーバー | 主な評価観点 |
|---|---|
| `APP01` | Azure VM / App Service / コンテナ化適性 |
| `DB01` | SQL Server → Azure SQL の適性 |
| `DC01` | 基盤系として残置または接続継続の検討 |

## 実施イメージ

- Azure Migrate プロジェクトを開く
- サーバーを検出またはインベントリ登録する
- 評価を実行する

## このフェーズで決めること

| パターン | 判断軸 |
|---|---|
| Rehost | とにかく早く移したいか |
| DB PaaS 化 | DB だけ先行してモダナイズしたいか |
| コンテナ化 | DevOps / 移植性 / スケール重視か |
| フル PaaS 化 | 運用負荷を最小化したいか |

## 次のステップ

- ➡ [`09-cloud-rehost.md`](./09-cloud-rehost.md)
- ➡ [`10-cloud-db-paas.md`](./10-cloud-db-paas.md)
- ➡ [`11-cloud-containerize.md`](./11-cloud-containerize.md)
- ➡ [`12-cloud-full-paas.md`](./12-cloud-full-paas.md)
