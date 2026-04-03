# 01. 移行元環境の確認

このフェーズでは、クラウド側の移行作業に入る前に、**移行元として使う疑似オンプレ環境を「移行観点」で整理**します。
`00c-onprem-verification.md` が疎通や正常動作の確認であるのに対し、ここでは **何を Azure に移行するのか、どの要素が依存しているのか** を把握することが目的です。

## 確認対象

| ホスト | 現在の役割 | 移行時の主な観点 |
|---|---|---|
| `DC01` | Active Directory / DNS | 認証・名前解決を担うため、移行先でも依存関係を意識する |
| `DB01` | SQL Server | データベースの移行先として VM 維持か Azure SQL かを検討する |
| `APP01` | IIS + Parts Unlimited | アプリ本体の移行先として VM / コンテナ / App Service を比較する |

## 参照先

詳細なセットアップや正常動作の確認は、同じ `docs/handson` 配下のオンプレ向けドキュメントを参照してください。

- [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md)
- [`00c-onprem-verification.md`](./00c-onprem-verification.md)

## このフェーズで整理するポイント

- **どのサーバーがどの役割を持っているか**
- **APP01 が DB01 / DC01 に依存していること**
- **アプリ、DB、認証基盤をそれぞれ別の移行パターンで比較できること**
- **以降の Arc / Migrate / Rehost / PaaS 化の対象がこの 3 台であること**

## クラウド HOL とのつながり

この整理を行うことで、以降の以下フェーズで**何を対象に評価・移行・モダナイズするのか**が明確になります。

- Azure Arc での登録
- Azure Migrate での評価
- Rehost / DB PaaS 化 / コンテナ化 / フル PaaS 化の比較

## 次のステップ

➡ [`02-cloud-arc-onboard.md`](./02-cloud-arc-onboard.md)
