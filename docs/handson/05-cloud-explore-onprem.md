# 05. 移行元環境の確認

このフェーズでは、クラウド側の移行作業に入る前に、**移行元として使う疑似オンプレ環境**の状態を確認します。

## 確認対象

| ホスト | 役割 |
|---|---|
| `DC01` | Active Directory / DNS |
| `DB01` | SQL Server |
| `APP01` | IIS + Parts Unlimited |

## 参照先

詳細なセットアップ・検証は、同じ `docs/handson` 配下のオンプレ向けドキュメントを参照してください。

- [`02-onprem-parts-unlimited.md`](./02-onprem-parts-unlimited.md)
- [`03-onprem-verification.md`](./03-onprem-verification.md)

## このフェーズで見るポイント

- `APP01` 上で `Parts Unlimited` が表示できる
- `APP01` から `DB01` に接続できる
- `DC01` がドメイン/DNS を提供している
- 移行元のネットワークが閉域前提である

## クラウド HOL とのつながり

この確認を行うことで、以降の以下フェーズで**何を Azure に移行するのか**が明確になります。

- Azure Arc での登録
- Azure Migrate での評価
- Spoke1～4 への移行パターン比較

## 次のステップ

➡ [`06-cloud-arc-onboard.md`](./06-cloud-arc-onboard.md)
