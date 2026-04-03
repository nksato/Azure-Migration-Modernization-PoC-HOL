# 12. フル PaaS 化（Spoke4）

`APP01` のアプリを .NET 8 化し、**Azure App Service + Azure SQL** に載せ替えるパターンです。

## 目的

- Web / DB ともに Azure のマネージドサービスへ寄せる
- インフラ運用の負荷を最小化する

## 移行先構成

| コンポーネント | 移行先 |
|---|---|
| Web | `app-spoke4` (App Service) |
| DB | `sqldb-spoke4` (Azure SQL) |
| 接続 | VNet Integration + Private Endpoint |

## 参照テンプレート

- `tmp/cloud/infra/modules/spoke-resources/spoke4-full-paas.bicep`

## 実施内容

1. Spoke4 の基盤をデプロイ
2. `APP01` のアプリを .NET 8 へ変換
3. App Service にデプロイ
4. Azure SQL に接続
5. ブラウザで URL を確認

## 特徴

- **メリット**: 運用負荷が最も低く、Azure ネイティブな構成になる
- **デメリット**: 変換・検証の初期コストがある

## 次のステップ

➡ [`13-cloud-compare.md`](./13-cloud-compare.md)
