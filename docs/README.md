# Azure Migration & Modernization HOL ドキュメント

移行元（疑似オンプレ）と移行先（クラウド）のドキュメントを整理しています。

---

## 📚 ドキュメント構成

### 0. 初期環境セットアップ

| ファイル | 内容 | 作業時間 | 備考 |
|---|---|---|---|
| [`handson/00-prerequisites.md`](./handson/00-prerequisites.md) | 作業環境の準備（Azure CLI / Git / クローン） | 5〜10 分 | ローカル PC / Codespaces / Cloud Shell の選択。**最初に実施** |
| [`handson/00-initial-setup.md`](./handson/00-initial-setup.md) | 初期環境を一括または 5 ステップで構築する導入手順（Deploy to Azure 対応） | 操作 5 分 + 待ち 60〜90 分 | 方法 A の場合。VPN Gateway 作成に時間を要する |

### 1. 移行元: 疑似オンプレ環境

| ファイル | 内容 | 作業時間 | 備考 |
|---|---|---|---|
| [`architecture-onprem-design.md`](./architecture-onprem-design.md) | 疑似オンプレ環境の設計方針・構成要素・テンプレート差分 | — | リファレンス |
| [`architecture-onprem-diagrams.md`](./architecture-onprem-diagrams.md) | Mermaid による移行元構成図・セットアップフロー | — | リファレンス |
| [`handson/00a-onprem-deploy.md`](./handson/00a-onprem-deploy.md) | 移行元インフラのデプロイ手順 | 操作 5 分 + 待ち 45〜60 分 | VM 3 台 + Bastion の作成 |
| [`handson/00b-onprem-parts-unlimited.md`](./handson/00b-onprem-parts-unlimited.md) | `DB01` / `APP01` のセットアップ手順 | 操作 5 分 + 待ち 15〜20 分 | セットアップスクリプトの実行待ち |
| [`handson/00c-onprem-verification.md`](./handson/00c-onprem-verification.md) | 動作確認・疎通確認手順 | 15〜20 分 | Bastion 接続 3 台 + CLI 確認コマンド。待ちなし |

### 2. 移行先: クラウド環境

| ファイル | 内容 | 作業時間 | 備考 |
|---|---|---|---|
| [`architecture-cloud-design.md`](./architecture-cloud-design.md) | Hub & Spoke / 移行パターン設計 | — | リファレンス |
| [`architecture-cloud-diagrams.md`](./architecture-cloud-diagrams.md) | クラウド構成図・移行フロー図 | — | リファレンス |
| [`handson/00d-cloud-deploy.md`](./handson/00d-cloud-deploy.md) | クラウド基盤のデプロイ | 操作 5 分 + 待ち 45〜60 分 | Hub/Spoke + Firewall + VPN Gateway + DNS Private Resolver |

### 3. ネットワーク接続: オンプレ ↔ クラウド

| ファイル | 内容 | 作業時間 | 備考 |
|---|---|---|---|
| [`handson/00e-cloud-vpn-connect.md`](./handson/00e-cloud-vpn-connect.md) | クラウド VPN 接続の構成 | 5〜10 分 | CLI コマンド数個。VPN Gateway 作成済み前提 |
| [`handson/00f-cloud-hybrid-dns.md`](./handson/00f-cloud-hybrid-dns.md) | ハイブリッド DNS の構成 | 5〜10 分 | CLI コマンド 3 つ（IP 取得・フォワーダー追加・確認） |
| [`architecture-vpn-s2s-bidirectional.md`](./architecture-vpn-s2s-bidirectional.md) | Azure 同士の S2S VPN 双方向設定の解説 | — | リファレンス |
| [`architecture-expressroute.md`](./architecture-expressroute.md) | ExpressRoute 接続の設計・設定（VPN との比較） | — | リファレンス |

### 4. クラウド移行 HOL

| ファイル | 内容 | 作業時間 | 備考 |
|---|---|---|---|
| [`handson/01-cloud-explore-onprem.md`](./handson/01-cloud-explore-onprem.md) | 移行元環境の確認 | 10〜15 分 | 座学中心。依存関係・移行対象の整理 |
| [`handson/02-cloud-arc-onboard.md`](./handson/02-cloud-arc-onboard.md) | Azure Arc 登録 | 操作 15〜20 分 + 待ち 5〜10 分 | スクリプト実行 + Arc エージェント登録待ち |
| [`handson/03-cloud-hybrid-mgmt.md`](./handson/03-cloud-hybrid-mgmt.md) | ハイブリッド管理 | 15〜20 分 | Portal 確認・KQL クエリ実行。待ちなし |
| [`handson/04-cloud-assessment.md`](./handson/04-cloud-assessment.md) | 移行アセスメント | 操作 30〜45 分 + 待ち 15 分 | アプライアンス VM 作成 + 検出反映待ち |
| [`handson/05a-cloud-rehost.md`](./handson/05a-cloud-rehost.md) | Rehost | 30〜45 分 | VM レプリケーション・テスト移行・カットオーバー |
| [`handson/05b-cloud-db-paas.md`](./handson/05b-cloud-db-paas.md) | DB PaaS 化 | 30〜45 分 | DMS 移行 + 接続文字列変更 + 動作確認 |
| [`handson/05c-cloud-containerize.md`](./handson/05c-cloud-containerize.md) | コンテナ化 | 45〜60 分 | .NET 8 変換 + Docker + ACR + Container Apps |
| [`handson/05d-cloud-full-paas.md`](./handson/05d-cloud-full-paas.md) | フル PaaS 化 | 30〜45 分 | .NET 8 変換 + App Service デプロイ |
| [`handson/06-cloud-compare.md`](./handson/06-cloud-compare.md) | 比較・まとめ | 10〜15 分 | 座学中心。4 パターンの振り返り |

### 5. お片付け

| ファイル | 内容 | 作業時間 | 備考 |
|---|---|---|---|
| [`handson/07-cloud-cleanup.md`](./handson/07-cloud-cleanup.md) | リソースのクリーンアップ | 5〜10 分 | リソースグループの削除。課金停止 |

---

## 🎯 このドキュメント群の役割

- `DC01` / `DB01` / `APP01` で構成された**移行元**を準備する
- Hub & Spoke を中心にした**移行先クラウド基盤**を整理する
- Rehost / DB PaaS 化 / コンテナ化 / フル PaaS 化を比較できるようにする

---

## 🚀 推奨の読み順

0. **作業環境を準備 → 初期環境をセットアップ**
   - [`handson/00-prerequisites.md`](./handson/00-prerequisites.md)
   - [`handson/00-initial-setup.md`](./handson/00-initial-setup.md)
1. **移行元を準備**
   - [`handson/00a-onprem-deploy.md`](./handson/00a-onprem-deploy.md)
   - [`handson/00b-onprem-parts-unlimited.md`](./handson/00b-onprem-parts-unlimited.md)
   - [`handson/00c-onprem-verification.md`](./handson/00c-onprem-verification.md)
2. **クラウド環境を準備**
   - [`handson/00d-cloud-deploy.md`](./handson/00d-cloud-deploy.md)
3. **ネットワーク接続を構成**
   - [`handson/00e-cloud-vpn-connect.md`](./handson/00e-cloud-vpn-connect.md)
   - [`handson/00f-cloud-hybrid-dns.md`](./handson/00f-cloud-hybrid-dns.md)
4. **クラウド移行 HOL を開始**
   - [`handson/01-cloud-explore-onprem.md`](./handson/01-cloud-explore-onprem.md)
   - [`handson/02-cloud-arc-onboard.md`](./handson/02-cloud-arc-onboard.md)
   - [`handson/03-cloud-hybrid-mgmt.md`](./handson/03-cloud-hybrid-mgmt.md)
   - [`handson/04-cloud-assessment.md`](./handson/04-cloud-assessment.md)
   - [`handson/05a-cloud-rehost.md`](./handson/05a-cloud-rehost.md)
   - [`handson/05b-cloud-db-paas.md`](./handson/05b-cloud-db-paas.md)
   - [`handson/05c-cloud-containerize.md`](./handson/05c-cloud-containerize.md)
   - [`handson/05d-cloud-full-paas.md`](./handson/05d-cloud-full-paas.md)
   - [`handson/06-cloud-compare.md`](./handson/06-cloud-compare.md)
5. **お片付け**
   - [`handson/07-cloud-cleanup.md`](./handson/07-cloud-cleanup.md)

---

## 🔗 関連ドキュメント

- [`../README.md`](../README.md)
- [`./architecture-onprem-design.md`](./architecture-onprem-design.md)
- [`./architecture-cloud-design.md`](./architecture-cloud-design.md)
