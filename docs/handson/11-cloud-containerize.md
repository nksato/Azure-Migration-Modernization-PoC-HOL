# 11. コンテナ化（Spoke3）

`APP01` のアプリを .NET 8 化し、**Azure Container Apps** に載せ替えるパターンです。

## 目的

- アプリをモダナイズしてコンテナ運用に移行する
- スケーラビリティとデプロイ柔軟性を高める

## 移行先構成

| コンポーネント | 移行先 |
|---|---|
| Web | `Container Apps` |
| イメージ格納 | `Azure Container Registry` |
| DB | `Azure SQL Database` |

## 参照テンプレート

- `tmp/cloud/infra/modules/spoke-resources/spoke3-container.bicep`

## 実施内容

1. Spoke3 の基盤をデプロイ
2. `APP01` のアプリを .NET 8 へ変換
3. Docker イメージを作成して ACR にプッシュ
4. Container Apps にデプロイ
5. Azure SQL へ接続

## 特徴

- **メリット**: スケールしやすく、モダンな運用に寄せられる
- **デメリット**: コード変換・コンテナ化の難易度が高い

## 次のステップ

➡ [`13-cloud-compare.md`](./13-cloud-compare.md)
