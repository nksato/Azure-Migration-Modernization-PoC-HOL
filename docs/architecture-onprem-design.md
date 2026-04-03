# 疑似オンプレ環境 on Azure - アーキテクチャ設計書

## 1. 目的

本環境は、Azure 上に**オンプレミス相当の 3 層構成**を再現し、後続の移行・モダナイズ HOL における**移行元システム**として利用するためのラボです。

### 想定するユースケース

- 移行前アプリケーションの現状確認
- Azure Arc によるハイブリッド管理の体験
- Azure Migrate による評価・移行準備
- Web / DB / 認証基盤を持つ典型的な Windows ワークロードの再現

---

## 2. 全体構成

疑似オンプレ環境は、Azure 上の 1 つの VNet に以下のコンポーネントを配置して構成します。

| レイヤー | 構成要素 | 役割 |
|---|---|---|
| ネットワーク | `OnPrem VNet (10.0.0.0/16)` | 移行元ネットワーク全体 |
| 認証基盤 | `DC01` | Active Directory / DNS |
| データベース | `DB01` | SQL Server 2022 Developer |
| アプリケーション | `APP01` | IIS + ASP.NET アプリ |
| 管理導線 | `Azure Bastion` | ブラウザ経由の RDP 接続 |
| 接続基盤 | `VPN Gateway` | Hub 側環境との S2S 接続を想定 |

---

## 3. サーバー構成

| Azure リソース名 | ホスト名 | 主な役割 | 代表 IP |
|---|---|---|---|
| `OnPrem-AD` | `DC01` | Active Directory / DNS | `10.0.1.4` |
| `OnPrem-SQL` | `DB01` | SQL Server | `10.0.1.5` |
| `OnPrem-Web` | `APP01` | IIS + ASP.NET 4.x | `10.0.1.6` |

### アプリケーション構成

| 項目 | 内容 |
|---|---|
| Web アプリ | Parts Unlimited |
| フレームワーク | ASP.NET MVC 5 / .NET Framework 系 |
| DB | SQL Server |
| 接続形態 | APP01 → DB01 |
| 管理アクセス | Azure Bastion 経由 |

---

## 4. ネットワーク設計

### サブネット構成

| サブネット | CIDR | 用途 |
|---|---|---|
| `ServerSubnet` | `10.0.1.0/24` | DC01 / DB01 / APP01 |
| `AzureBastionSubnet` | `10.0.254.0/26` | Azure Bastion |
| `GatewaySubnet` | `10.0.255.0/27` | VPN Gateway |

### 設計ポイント

- 各 VM に**パブリック IP は付与しない**
- 管理アクセスは **Azure Bastion** に統一
- ドメイン/DNS は `DC01` が提供
- 将来的なクラウド側 Hub VNet 接続を見据えて **VPN Gateway** を同居

---

## 5. 使用テンプレート

ハンズオンでは、`infra/onprem/main.bicep` を標準構成として利用します。

| テンプレート | 特徴 | 用途 |
|---|---|---|
| `main.bicep` | Azure 既定の送信アクセスを利用 | 標準ラボ構成 |

---

## 6. デプロイとセットアップの流れ

1. インフラをデプロイ
2. `DC01` で AD/DNS を構成
3. `DB01` / `APP01` をドメイン参加
4. `DB01` に SQL Server をセットアップ
5. `APP01` に Parts Unlimited をデプロイ
6. 疎通・画面表示を確認

詳細手順は以下を参照してください。

- [`handson/00a-onprem-deploy.md`](./handson/00a-onprem-deploy.md)
- [`handson/00b-onprem-parts-unlimited.md`](./handson/00b-onprem-parts-unlimited.md)
- [`handson/00c-onprem-verification.md`](./handson/00c-onprem-verification.md)

---

## 7. Azure Arc（オプション）

この環境は、必要に応じて Azure Arc の評価対象としても利用できます。

| 項目 | 内容 |
|---|---|
| 対象 | `DC01`, `DB01`, `APP01` |
| 目的 | ハイブリッド管理 / ポリシー / 更新管理 / Defender 評価 |
| 参照スクリプト | `infra/onprem/Enable-ArcOnVMs.ps1` |

---

## 8. 参照ファイル

- `tmp/onprem/README.md`
- `infra/onprem/Deploy-Lab.ps1`
- `infra/onprem/main.bicep`
- `infra/onprem/Enable-ArcOnVMs.ps1`
- `infra/onprem/scripts/*`

> この設計書は、移行元環境に関する正式な `docs` 配下の初版です。今後はクラウド側や全体 HOL 設計書と並ぶ形で拡張していきます。
