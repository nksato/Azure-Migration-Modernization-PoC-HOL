# 検証スクリプト リファレンス

本プロジェクトでは、デプロイ後の構成確認を自動化する **5 つの Verify スクリプト** を提供しています。  
各スクリプトは Azure CLI（`az vm run-command invoke` 含む）で検証を行い、`[PASS]` / `[FAIL]` 形式で結果を出力します。

---

## スクリプト一覧

| # | スクリプト | 対象 | 実行タイミング | 備考 |
|---|---|---|---|---|
| 1 | [`Verify-OnpremSetup.ps1`](#1-verify-onpremsetupps1) | rg-onprem | オンプレ環境デプロイ後 | VM 内部にリモート実行 |
| 2 | [`Verify-CloudDeploy.ps1`](#2-verify-clouddeployps1) | rg-hub, rg-spoke1〜4 | クラウド基盤デプロイ後 | Azure API のみ |
| 3 | [`Verify-VpnConnection.ps1`](#3-verify-vpnconnectionps1) | rg-onprem, rg-hub | VPN 接続構成後 | Azure API のみ |
| 4 | [`Verify-HybridDns.ps1`](#4-verify-hybriddnsps1) | rg-onprem, rg-hub | ハイブリッド DNS 構成後 | VM 内部にリモート実行 |
| 5 | [`Verify-ArcOnboarding.ps1`](#5-verify-arconboardingps1) | rg-onprem | Azure Arc オンボーディング後 | VM 内部にリモート実行 |

### デプロイフローと実行順

```
1.2-onprem-deploy → 1.3-onprem-parts-unlimited → [1] Verify-OnpremSetup
1.5-cloud-deploy                                → [2] Verify-CloudDeploy
1.6-cloud-vpn-connect                           → [3] Verify-VpnConnection
1.7-cloud-hybrid-dns                            → [4] Verify-HybridDns
2.2-cloud-arc-onboard                            → [5] Verify-ArcOnboarding
```

---

## 1. Verify-OnpremSetup.ps1

**パス:** `infra/onprem/scripts/Verify-OnpremSetup.ps1`

疑似オンプレ環境（`rg-onprem`）のセットアップ状態をリモートから検証します。  
`az vm run-command invoke` で各 VM 内のコマンドを実行し、結果をローカルで判定します。Bastion 接続は不要です。

### パラメータ

| パラメータ | 既定値 | 説明 |
|---|---|---|
| `-ResourceGroupName` | `rg-onprem` | 対象リソースグループ |
| `-SkipPartsUnlimited` | — | Parts Unlimited の確認をスキップ |

### 使用方法

```powershell
.\Verify-OnpremSetup.ps1
.\Verify-OnpremSetup.ps1 -SkipPartsUnlimited
```

### チェック項目

| # | カテゴリ | チェック内容 |
|---|---|---|
| 0 | リソースグループ | `rg-onprem` の存在確認 |
| 1 | VM の状態 | `vm-onprem-ad` / `vm-onprem-sql` / `vm-onprem-web` が起動中 |
| 2 | パブリック IP なし | 各 VM の NIC にパブリック IP が未割り当て |
| 3 | DC01: AD + DNS | AD ドメイン取得、DNS ゾーン一致、PDC Emulator 検出 |
| 4 | DB01: SQL Server | SQL Server サービス稼働、ドメイン参加済み、F:\SQLData 存在 |
| 5 | APP01: IIS | IIS / ASP.NET 4.5 インストール、ドメイン参加、HTTP 200 応答 |
| 5+ | APP01: Parts Unlimited | サイトに "Parts Unlimited" の文字列が含まれる (`-SkipPartsUnlimited` でスキップ可) |
| 6 | 内部疎通 | APP01 → DB01:1433、APP01 → DC01:3389、DNS 名前解決 |

---

## 2. Verify-CloudDeploy.ps1

**パス:** `infra/cloud/scripts/Verify-CloudDeploy.ps1`

クラウド基盤（Hub & Spoke）のデプロイ状態を検証します。  
Azure API のみで完結し、VM 内部への接続は行いません。

### パラメータ

| パラメータ | 既定値 | 説明 |
|---|---|---|
| `-SkipFirewall` | — | Azure Firewall の確認をスキップ |
| `-SkipBastion` | — | Azure Bastion の確認をスキップ |

### 使用方法

```powershell
.\Verify-CloudDeploy.ps1
.\Verify-CloudDeploy.ps1 -SkipFirewall -SkipBastion
```

### チェック項目

| # | カテゴリ | チェック内容 |
|---|---|---|
| 1 | リソースグループ | `rg-hub` / `rg-spoke1` 〜 `rg-spoke4` の存在確認 |
| 2 | VNet & アドレス空間 | 5 VNet のアドレス空間が正しい CIDR |
| 3 | Hub サブネット | 6 サブネット (`AzureFirewallSubnet`, `AzureFirewallManagementSubnet`, `AzureBastionSubnet`, `GatewaySubnet`, `snet-dns-inbound`, `snet-dns-outbound`) |
| 4 | Spoke サブネット | 各 Spoke の 2 サブネット（`snet-web`/`snet-db`/`snet-aca`/`snet-appservice`/`snet-pep`） |
| 5 | VNet ピアリング | Hub → Spoke1〜4 の peeringState が `Connected` |
| 6 | Azure Firewall | `afw-hub` のプロビジョニング、`afwp-hub` ポリシー、`rt-spokes-to-fw` ルートテーブル |
| 7 | Azure Bastion | `bas-hub` のプロビジョニング |
| 8 | DNS | `dnspr-hub` (Resolver + Inbound/Outbound Endpoint)、`privatelink.database.windows.net` (Private DNS Zone + VNet リンク ≥ 4) |
| 9 | Log Analytics | `log-hub` のプロビジョニング |
| 10 | ポリシー割り当て | 7 ポリシー (`policy-allowed-locations`, `policy-storage-no-public`, `policy-sql-auditing`, `policy-sql-no-public`, `policy-require-env-tag`, `policy-mgmt-ports-audit`, `policy-appservice-no-public`) |

---

## 3. Verify-VpnConnection.ps1

**パス:** `infra/network/scripts/Verify-VpnConnection.ps1`

VPN Gateway の配置と S2S 接続の状態を検証します。  
Azure API のみで完結します。

### パラメータ

パラメータなし。

### 使用方法

```powershell
.\Verify-VpnConnection.ps1
```

### チェック項目

| # | カテゴリ | チェック内容 |
|---|---|---|
| 1 | GatewaySubnet | `vnet-onprem` / `vnet-hub` に `GatewaySubnet` が存在 |
| 2 | VPN GW (オンプレ) | `vgw-onprem` — プロビジョニング `Succeeded`、SKU `VpnGw1AZ`、タイプ `RouteBased`、Public IP 取得 |
| 3 | VPN GW (Hub) | `vpngw-hub` — プロビジョニング `Succeeded`、SKU `VpnGw1AZ`、タイプ `RouteBased`、Public IP 取得 |
| 4 | Local Network GW | `lgw-hub` — プロビジョニング、PIP 一致、アドレス空間 `10.10.0.0/16` + Spoke (`10.20-23.0.0/16`) |
| 5 | S2S VPN 接続 | `cn-onprem-to-hub` — プロビジョニング `Succeeded`、接続状態 `Connected`、プロトコル `IKEv2` |
| 6 | 接続情報サマリ | 両側の Public IP・LGW 設定・接続状態の一覧表示 |
| 7 | Gateway Transit | Hub→Spoke ピアリングの `allowGatewayTransit = true`、Spoke→Hub の `useRemoteGateways = true` |

---

## 4. Verify-HybridDns.ps1

**パス:** `infra/network/scripts/Verify-HybridDns.ps1`

ハイブリッド DNS 構成の状態と双方向の名前解決を検証します。  
Azure API と `az vm run-command invoke` を使用して、DNS 設定と実際の名前解決結果を確認します。

### パラメータ

| パラメータ | 既定値 | 説明 |
|---|---|---|
| `-OnpremResourceGroup` | `rg-onprem` | オンプレリソースグループ |
| `-HubResourceGroup` | `rg-hub` | Hub リソースグループ |

### 使用方法

```powershell
.\Verify-HybridDns.ps1
```

### チェック項目

| # | カテゴリ | チェック内容 |
|---|---|---|
| 1 | DNS Private Resolver | `dnspr-hub` プロビジョニング、Inbound IP 取得、Outbound Endpoint |
| 2 | DNS Forwarding Ruleset | `dnsrs-hub` プロビジョニング、`lab.local` → `10.0.1.4` (DC01) 転送ルール、VNet リンク |
| 3 | DC01 条件付きフォワーダー | `privatelink.database.windows.net` の Forwarder 種別、転送先が DNS Resolver Inbound IP と一致 |
| 4 | 設定情報サマリ | Inbound IP・Ruleset・転送ルール・条件付きフォワーダーの一覧表示 |
| 5 | オンプレ → クラウド | DC01 から `privatelink.database.windows.net` の名前解決 |
| 6 | クラウド → オンプレ | DC01 → AD ドメイン解決、`vm-spoke1-web` → `lab.local` 解決 (Spoke VM 存在時のみ) |
| 7 | VPN 経由の基本疎通 | DC01 → Hub DNS (10.10.5.4)、DC01 → Hub FW (10.10.1.4) への ICMP (参考値) |

---

## 5. Verify-ArcOnboarding.ps1

**パス:** `infra/onprem/scripts/Verify-ArcOnboarding.ps1`

Azure Arc オンボーディングの状態をリモートから検証します。  
Azure API で Arc リソースの存在を確認し、`az vm run-command invoke` で VM 内の Connected Machine Agent の状態を確認します。

### パラメータ

| パラメータ | 既定値 | 説明 |
|---|---|---|
| `-ResourceGroupName` | `rg-onprem` | VM の所属リソースグループ |
| `-ArcResourceGroupName` | (空 = ResourceGroupName) | Arc リソースの登録先グループ |
| `-VmNames` | `vm-onprem-ad`, `vm-onprem-sql`, `vm-onprem-web` | 検証対象の VM 名 |

### 使用方法

```powershell
.\Verify-ArcOnboarding.ps1
.\Verify-ArcOnboarding.ps1 -ArcResourceGroupName "rg-arc"
```

### チェック項目（VM ごとに繰り返し）

| # | カテゴリ | チェック内容 |
|---|---|---|
| 1 | Azure Arc リソース | `{vmName}-Arc` リソースの存在、接続状態 `Connected`、エージェントバージョン |
| 2 | Arc 対応準備 | 環境変数 `MSFT_ARC_TEST = true`、ゲストエージェント停止 (`Stopped` + `Disabled`)、IMDS ブロック (169.254.169.254 / 169.254.169.253) |
| 3 | Connected Machine Agent | エージェントインストール済み、状態 `Connected`、リソース名・リソースグループの一致 |

---

## 共通仕様

### 出力形式

全スクリプトは統一されたテスト出力形式を使用します。

```
=== カテゴリ名 ===
  [PASS] チェック項目: 実際の値
  [FAIL] チェック項目: 実際の値

=== 結果: N / M 通過 ===
```

### 共通ヘルパー関数

| 関数 | 用途 |
|---|---|
| `Test-Val` | 文字列の完全一致を検証 |
| `Test-NotEmpty` | 値が空でないことを検証 |
| `Test-Bool` | ブール値が `true` であることを検証 |
| `Test-Match` | 正規表現パターンに一致することを検証 |
| `Invoke-VmCommand` | `az vm run-command invoke` のラッパー |
| `Get-Val` | コマンド出力から `KEY=VALUE` 形式の値を抽出 |

### 前提条件

- Azure CLI (`az`) がインストールされ、対象サブスクリプションにログイン済み
- `az vm run-command invoke` を使うスクリプト (1, 4, 5) は対象 VM が起動中であること
- Bastion 接続は **不要**（全てローカルから Azure API 経由で実行可能）

---

## 関連ドキュメント

- オンプレ環境の確認手順: [`handson/1.4-onprem-verification.md`](./handson/1.4-onprem-verification.md)
- クラウド基盤デプロイ: [`handson/1.5-cloud-deploy.md`](./handson/1.5-cloud-deploy.md)
- VPN 接続構成: [`../handson/1.6-cloud-vpn-connect.md`](../handson/1.6-cloud-vpn-connect.md)
- ハイブリッド DNS 構成: [`../handson/1.7-cloud-hybrid-dns.md`](../handson/1.7-cloud-hybrid-dns.md)
- Azure Arc オンボーディング: [`../handson/2.2-cloud-arc-onboard.md`](../handson/2.2-cloud-arc-onboard.md)
- オンプレ設計: [`architecture-onprem-design.md`](./architecture-onprem-design.md)
- クラウド設計: [`architecture-cloud-design.md`](./architecture-cloud-design.md)
