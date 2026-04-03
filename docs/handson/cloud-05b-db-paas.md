# Phase 5b: DB PaaS 化（Spoke2）

Web アプリは VM のまま、`DB01` のデータベースを **Azure SQL Database** に移行するパターンです。

## 目的

- DB を先にマネージド化する
- アプリ変更を比較的小さく保ちながら運用負荷を下げる

## 移行先構成

| コンポーネント | 移行先 |
|---|---|
| Web | `vm-spoke2-web` |
| DB | `sqldb-spoke2` |
| 接続方式 | Private Endpoint |

## 参照テンプレート

- `tmp/cloud/infra/modules/spoke-resources/spoke2-db-paas.bicep`

## 実施内容

1. Spoke2 の受け皿をデプロイ
2. DMS などで `DB01` から Azure SQL へ移行
3. アプリの接続文字列を Azure SQL 向けに変更
4. `vm-spoke2-web` で動作確認

## 特徴

- **メリット**: DB 運用の負荷を先に下げられる
- **デメリット**: Web は引き続き VM 管理が必要

## 次のステップ

➡ [`cloud-06-compare.md`](./cloud-06-compare.md)
