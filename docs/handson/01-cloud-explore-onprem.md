# 01. 移行元環境の確認

クラウド側の移行作業に入る前に、疑似オンプレ環境を「移行観点」で整理します。  
`00c` が疎通・正常動作の確認であるのに対し、ここでは何を Azure に移行するのか、どの要素が依存しているのかを把握します。

## 目的

- 各サーバーの役割と依存関係を把握する
- 移行対象となるコンポーネントを明確にする
- 以降の Arc / Migrate / 各移行パターンの対象範囲を確定させる

## 前提条件

- [`00c-onprem-verification.md`](./00c-onprem-verification.md) の確認が完了している

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

## 整理するポイント

- 各サーバーの役割と依存関係（APP01 → DB01 / DC01）
- アプリ、DB、認証基盤をそれぞれ別の移行パターンで比較できること
- 以降の Arc / Migrate / Rehost / PaaS 化の対象がこの 3 台であること

この整理により、以降の Azure Arc 登録・Azure Migrate 評価・各移行パターンの対象が明確になります。

## 次のステップ

➡ [`02-cloud-arc-onboard.md`](./02-cloud-arc-onboard.md)
