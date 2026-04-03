# 05a. Rehost（Spoke1）

最小限の変更で、`APP01` と `DB01` を Azure VM に移行するパターンです。

## 目的

- Lift & Shift の基本パターンを体験する
- 既存資産への変更を最小化する

## 移行先構成

| コンポーネント | 移行先 |
|---|---|
| `APP01` | `vm-spoke1-web` |
| `DB01` | `vm-spoke1-sql` |

## 参照テンプレート

- `infra/cloud/modules/spoke-resources/spoke1-rehost.bicep`

## 手順イメージ

1. Spoke1 の受け皿リソースをデプロイ
2. Azure Migrate で VM レプリケーションを設定
3. テスト移行を実施
4. カットオーバー後にアプリ動作確認

## 特徴

- **メリット**: 変更が少なく、移行が速い
- **デメリット**: VM 運用が継続し、運用負荷は高い

## 次のステップ

➡ [`06-cloud-compare.md`](./06-cloud-compare.md)
