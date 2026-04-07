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
| ネットワーク | `vnet-onprem (10.0.0.0/16)` | 移行元ネットワーク全体 |
| セキュリティ | `nsg-server` | VNet 内通信のみ許可 (インターネット Inbound 拒否) |
| 認証基盤 | `DC01` | Active Directory / DNS |
| データベース | `DB01` | SQL Server 2019 Developer |
| アプリケーション | `APP01` | IIS + ASP.NET アプリ |
| 管理導線 | `bas-onprem` (Azure Bastion Basic) | ブラウザ経由の RDP 接続 |
| 接続基盤 | `vgw-onprem` (VPN Gateway) | Hub 側環境との S2S 接続 |

### サブネット構成

| サブネット | CIDR | 用途 |
|---|---|---|
| `ServerSubnet` | `10.0.1.0/24` | DC01 / DB01 / APP01 |
| `AzureBastionSubnet` | `10.0.254.0/26` | Azure Bastion |
| `GatewaySubnet` | `10.0.255.0/27` | VPN Gateway |

---

## 3. リソース構成

### サーバー構成

| Azure リソース名 | ホスト名 | 主な役割 | 代表 IP | OS | VM サイズ |
|---|---|---|---|---|---|
| `vm-onprem-ad` | `DC01` | Active Directory / DNS | `10.0.1.4` | Windows Server 2022 Datacenter | Standard_B2s_v2 |
| `vm-onprem-sql` | `DB01` | SQL Server 2019 Developer | `10.0.1.5` | Windows Server 2019 (SQL 2019 イメージ) | Standard_B2s_v2 |
| `vm-onprem-web` | `APP01` | IIS + ASP.NET 4.x | `10.0.1.6` | Windows Server 2019 Datacenter | Standard_B2s_v2 |

### アプリケーション構成

| 項目 | 内容 |
|---|---|
| Web アプリ | Parts Unlimited |
| フレームワーク | ASP.NET MVC 5 / .NET Framework 系 |
| DB | SQL Server |
| 接続形態 | APP01 → DB01 |
| 管理アクセス | Azure Bastion 経由 |

### Azure Arc

この環境は、Azure Arc の評価対象としても利用できます。

| 項目 | 内容 |
|---|---|
| 対象 | `DC01`, `DB01`, `APP01` |
| 目的 | ハイブリッド管理 / ポリシー / 更新管理 / Defender 評価 |
| 参照スクリプト | `infra/onprem/Convert-VmToArc.ps1` |

---

## 4. ネットワーク設計

- 各 VM に**パブリック IP は付与しない**
- 管理アクセスは **Azure Bastion** に統一
- VM の送信インターネットアクセスは **NAT Gateway** (`ng-onprem`) 経由（`defaultOutboundAccess` は無効化）
- ドメイン/DNS は `DC01` が提供（VNet の `dhcpOptions.dnsServers` に `10.0.1.4` を設定）
- `nsg-server` で VNet 内通信のみ許可、インターネットからの Inbound は拒否
- `GatewaySubnet` はクラウド側 Hub VNet との S2S 接続用（VPN Gateway は別テンプレートで作成）

---

## 5. ネットワーク接続と DNS

疑似オンプレ環境は、クラウド側 Hub VNet と **S2S VPN** で接続します。この構成はオンプレ基盤とは別のテンプレート (`infra/network/`) でデプロイされます。

### VPN 構成

| リソース | リソース名 | リソースグループ | 備考 |
|---|---|---|---|
| VPN Gateway | `vgw-onprem` | rg-onprem | VpnGw1AZ / RouteBased |
| Public IP | `vgw-onprem-pip1` | rg-onprem | Standard / Static / ゾーン冗長 |
| Local Network GW | `lgw-hub` | rg-onprem | Hub + Spoke を表す (10.10.0.0/16, 10.20-23.0.0/16) |
| S2S 接続 | `cn-onprem-to-hub` | rg-onprem | IKEv2 |
| Local Network GW | `lgw-onprem` | rg-hub | オンプレ側を表す (10.0.0.0/16) |
| S2S 接続 | `cn-hub-to-onprem` | rg-hub | IKEv2 |

### DNS 構成

| 方向 | 解決手段 | 構成場所 |
|---|---|---|
| クラウド → オンプレ (`lab.local`) | DNS Forwarding Ruleset (`dnsrs-hub`) | `infra/cloud/main.bicep` で自動作成 |
| オンプレ → クラウド (`privatelink.database.windows.net`) | DC01 の DNS 条件付きフォワーダー | デプロイ後に**手動設定** |

> `GatewaySubnet` は `infra/onprem/resources.bicep` には含まれず、`infra/network/modules/onprem-vpn-gateway.bicep` がデプロイ時に追加します。

---

## 6. デプロイ

### 使用テンプレート

ハンズオンでは、`infra/onprem/main.bicep` をエントリポイントとして利用します。

| テンプレート | 特徴 | 用途 |
|---|---|---|
| `infra/onprem/main.bicep` | サブスクリプションスコープ ラッパー | RG 作成 + resources.bicep 呼び出し |
| `infra/onprem/resources.bicep` | NAT Gateway で送信アクセスを提供 | VM / VNet / Bastion / NSG / NAT Gateway |
| `infra/network/main.bicep` | VPN Gateway + S2S 接続 | オンプレ・ Hub 両方の VPN GW + 接続 |
| `infra/main.bicep` | 一括デプロイ用エントリポイント | 上記をまとめて実行 |

### デプロイとセットアップの流れ

Bicep テンプレートのデプロイにより、以下の 1 ～ 3 は**自動的に実行**されます。

1. インフラをデプロイ（VNet / NSG / Bastion / VM）
2. `DC01` で AD DS / DNS を構成（CustomScriptExtension で自動実行）
3. `DB01` / `APP01` をドメイン参加（JsonADDomainExtension で自動実行）
4. `DB01` に SQL Server のデータドライブを構成（SqlVirtualMachine リソースで自動実行）
5. `APP01` に Parts Unlimited をデプロイ（**手動**）
6. 疎通・画面表示を確認

詳細手順は以下を参照してください。

- [`handson/1.2-onprem-deploy.md`](./handson/1.2-onprem-deploy.md)
- [`handson/1.3-onprem-parts-unlimited.md`](./handson/1.3-onprem-parts-unlimited.md)
- [`handson/1.4-onprem-verification.md`](./handson/1.4-onprem-verification.md)

---

## 7. 関連ドキュメント

- クラウド設計: [`./architecture-cloud-design.md`](./architecture-cloud-design.md)
- オンプレ図解: [`./architecture-onprem-diagrams.md`](./architecture-onprem-diagrams.md)
- クラウド図解: [`./architecture-cloud-diagrams.md`](./architecture-cloud-diagrams.md)
- 検証スクリプト: [`./architecture-verify-scripts.md`](./architecture-verify-scripts.md)
- オンプレデプロイ: [`./handson/1.2-onprem-deploy.md`](./handson/1.2-onprem-deploy.md)
- Parts Unlimited セットアップ: [`./handson/1.3-onprem-parts-unlimited.md`](./handson/1.3-onprem-parts-unlimited.md)
- 動作確認: [`./handson/1.4-onprem-verification.md`](./handson/1.4-onprem-verification.md)
- VPN 接続: [`./handson/1.6-cloud-vpn-connect.md`](./handson/1.6-cloud-vpn-connect.md)
- ハイブリッド DNS: [`./handson/1.7-cloud-hybrid-dns.md`](./handson/1.7-cloud-hybrid-dns.md)

### 参照ファイル一覧

- `infra/onprem/main.bicep` — サブスクリプションスコープ ラッパー
- `infra/onprem/resources.bicep` — リソースグループスコープ (VM / VNet / Bastion / NSG / NAT Gateway)
- `infra/network/main.bicep` — VPN Gateway + S2S 接続
- `infra/network/modules/onprem-vpn-gateway.bicep`
- `infra/network/modules/vpn-connection.bicep`
- `infra/network/modules/vpn-connection-hub.bicep`
- `infra/main.bicep` — 一括デプロイ用エントリポイント
- `infra/onprem/Convert-VmToArc.ps1` — Azure Arc オンボーディング
- `infra/onprem/scripts/*` — セットアップスクリプト群
