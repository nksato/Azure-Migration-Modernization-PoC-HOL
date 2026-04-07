# ハイブリッド DNS 設計 — Azure DNS Private Resolver を中心とした名前解決

## 概要

本 HOL では、疑似オンプレ環境（`rg-onprem`）とクラウド Hub-Spoke 環境の間で **Azure DNS Private Resolver** を中心にした双方向 DNS 転送を構成しています。VPN 接続だけでは名前解決ができないため、DNS 転送設定が必要です。

`Setup-HybridDns.ps1` は 3 段階のステップと 2 つのオプションスイッチで、基本構成から発展構成までカバーします。

| ステップ | 方向 | 内容 | 必須/オプション |
|---------|------|------|---------------|
| [1/3] | クラウド → オンプレ | DNS Forwarding Ruleset で `lab.local` を DC01 へ転送 | 必須 |
| [2/3] | オンプレ → クラウド PaaS | DC01 に `privatelink.database.windows.net` の条件付きフォワーダーを追加 | 必須 |
| [3/3] | オンプレ → クラウド VM | Private DNS Zone (`azure.internal`) + DC01 条件付きフォワーダー | `-EnableCloudVmResolution` |

| スイッチ | 効果 |
|---------|------|
| `-LinkSpokeVnets` | Forwarding Ruleset を Spoke VNet にもリンク（Spoke VM → オンプレ名前解決） |
| `-EnableCloudVmResolution` | [3/3] を有効化（オンプレ → クラウド VM ホスト名解決） |

本ドキュメントでは、ハイブリッド DNS の設計思想、構成要素、および Azure 閉域内での名前解決パターンをまとめます。

---

## 全体像

```
疑似オンプレ (10.0.0.0/16)                    クラウド / Hub (10.10.0.0/16)
┌─────────────────────┐                      ┌──────────────────────────────────────┐
│  DC01 (10.0.1.4)    │                      │  DNS Private Resolver (dnspr-hub)    │
│  ┌────────────────┐ │   VPN (S2S)          │  ┌────────────┐                     │
│  │ DNS Server     │◄├──────────────────────├──┤ Outbound   │ [1/3] lab.local     │
│  │                │ │  Forwarding          │  │ Endpoint   │ → DC01 へ転送       │
│  │ 条件付き FW:   │ │  Ruleset             │  └────────────┘                     │
│  │                │ │                      │                                      │
│  │ privatelink.*  │─├──────────────────────├─►┌────────────┐                     │
│  │ [2/3]          │ │                      │  │ Inbound    │ Azure DNS に         │
│  │                │ │                      │  │ Endpoint   │ 中継解決             │
│  │ azure.internal │─├──────────────────────├─►│ 10.10.5.4  │                     │
│  │ [3/3] オプション │ │                      │  └─────┬──────┘                     │
│  └────────────────┘ │                      │        │                              │
└─────────────────────┘                      │  ┌─────▼────────────────────────┐    │
                                             │  │ Private DNS Zones            │    │
                                             │  │                              │    │
                                             │  │ privatelink.database.        │    │
                                             │  │   windows.net [2/3]          │    │
                                             │  │   → PE の IP を解決           │    │
                                             │  │                              │    │
                                             │  │ azure.internal [3/3]         │    │
                                             │  │   → VM ホスト名を解決         │    │
                                             │  └──────────────────────────────┘    │
                                             └──────────────────────────────────────┘
                                                       │
                                          ┌────────────┼─ Spoke VNets ──────────┐
                                          │            │                        │
                                    vnet-spoke1   vnet-spoke2            vnet-spoke4
                                    10.20.0.0/16  10.21.0.0/16          10.23.0.0/16
                                    ┌──────────┐  ┌──────────┐          ┌──────────┐
                                    │ VM       │  │ PE (SQL) │          │ PE (App) │
                                    │ IaaS     │  │ PaaS     │          │ PaaS     │
                                    └──────────┘  └──────────┘          └──────────┘
                                    azure.internal  privatelink.          privatelink.
                                    で自動登録       database.             azurewebsites.
                                                   windows.net           net
```

### Spoke VNet からオンプレへの名前解決 (`-LinkSpokeVnets`)

```
Spoke VM                    Hub                          オンプレ
┌─────────┐  VNet Peering  ┌──────────────┐    VPN     ┌──────────┐
│ Spoke1  │ ──────────────►│ Forwarding   │ ─────────► │ DC01     │
│ VM      │    DNS query    │ Ruleset      │ lab.local  │ DNS      │
│         │                │ (dnsrs-hub)  │ クエリ転送  │          │
└─────────┘                └──────────────┘            └──────────┘
                  ▲ link-vnet-spoke1 (要 -LinkSpokeVnets)
```

> `-LinkSpokeVnets` を指定しない場合、Spoke VNet には Forwarding Ruleset がリンクされず、Spoke VM から `lab.local` の名前解決はできません。

### オンプレからクラウド VM の名前解決 (`-EnableCloudVmResolution`)

```
オンプレ                         Hub                          Spoke VNets
┌──────────┐    VPN            ┌──────────────┐              ┌──────────────┐
│ DC01     │ ─────────────────►│ Inbound      │    Azure     │ vnet-spoke1  │
│ 条件付き  │  azure.internal   │ Endpoint     │◄── DNS ──── │  VM の A レコ │
│ FW       │  クエリ転送        │ 10.10.5.4    │    解決      │  ードを自動登録│
└──────────┘                   └──────┬───────┘              └──────────────┘
                                     │                              │
                               ┌─────▼──────────────┐    VNet Link │
                               │ Private DNS Zone    │◄────────────┘
                               │ azure.internal      │  (Registration 有効)
                               │  vm-spoke1-web → IP │
                               └─────────────────────┘
```

> `-EnableCloudVmResolution` を指定しない場合、Private DNS Zone `azure.internal` は作成されず、オンプレからクラウド VM のホスト名解決はできません（IP 直接指定は可能）。

---

## DNS 転送の方向と構成要素

| ステップ | 方向 | 転送元 | 転送先 | 対象ゾーン | 仕組み | スイッチ |
|---------|------|--------|--------|-----------|--------|---------|
| [1/3] | クラウド → オンプレ | DNS Private Resolver（Outbound） | DC01（`10.0.1.4:53`） | `lab.local` | DNS Forwarding Ruleset | — |
| [1/3] | Spoke → オンプレ | 同上（Spoke VNet からも） | 同上 | `lab.local` | Ruleset VNet Link | `-LinkSpokeVnets` |
| [2/3] | オンプレ → クラウド PaaS | DC01（条件付きフォワーダー） | DNS Private Resolver（Inbound `10.10.5.4`） | `privatelink.database.windows.net` | Windows DNS 条件付きフォワーダー | — |
| [3/3] | オンプレ → クラウド VM | DC01（条件付きフォワーダー） | DNS Private Resolver（Inbound `10.10.5.4`） | `azure.internal` | Private DNS Zone + 条件付きフォワーダー | `-EnableCloudVmResolution` |

---

## 必要なリソース

### [1/3] クラウド → オンプレ（Forwarding Ruleset）

#### Azure 側（rg-hub）

| # | リソース名 | リソースタイプ | 役割 |
|---|-----------|--------------|------|
| 1 | `dnspr-hub` | DNS Private Resolver | 名前解決の中核。Inbound / Outbound Endpoint を持つ |
| 2 | Inbound Endpoint | DNS Private Resolver Endpoint | オンプレ / クラウドからの DNS クエリを受け付ける（`10.10.5.4`） |
| 3 | Outbound Endpoint | DNS Private Resolver Endpoint | オンプレ DNS への転送クエリを送出する |
| 4 | `dnsrs-hub` | DNS Forwarding Ruleset | Outbound Endpoint に紐付く転送ルールの集合 |
| 5 | `rule-lab-local` | Forwarding Rule | `lab.local.` → DC01（`10.0.1.4:53`）への転送ルール |
| 6 | `link-vnet-hub` | VNet Link（Ruleset） | Forwarding Ruleset を Hub VNet にリンク |

**`-LinkSpokeVnets` 指定時に追加:**

| # | リソース名 | リソースタイプ | 役割 |
|---|-----------|--------------|------|
| 7 | `link-vnet-spoke1` ～ `link-vnet-spoke4` | VNet Link（Ruleset） | Forwarding Ruleset を Spoke VNet にリンク。Spoke VM から `lab.local` を解決可能にする |

### [2/3] オンプレ → クラウド PaaS（条件付きフォワーダー）

#### オンプレ側（DC01）

| # | 設定 | 内容 |
|---|------|------|
| 1 | 条件付きフォワーダー | `privatelink.database.windows.net` → `10.10.5.4`（Inbound Endpoint） |

> Inbound Endpoint が受けたクエリは Azure DNS に中継され、Hub VNet にリンクされた Private DNS Zone のレコードを解決します。

### [3/3] オンプレ → クラウド VM（`-EnableCloudVmResolution` 指定時のみ）

#### Azure 側（rg-hub）

| # | リソース名 | リソースタイプ | 役割 |
|---|-----------|--------------|------|
| 1 | `azure.internal` | Private DNS Zone | クラウド VM のホスト名を管理するゾーン |
| 2 | `link-vnet-hub` | VNet Link（Private DNS Zone） | Hub VNet からの解決を有効化（自動登録なし） |
| 3 | `link-vnet-spoke1` ～ `link-vnet-spoke4` | VNet Link（Private DNS Zone） | Spoke VNet の VM を自動登録（Registration 有効） |

#### オンプレ側（DC01）

| # | 設定 | 内容 |
|---|------|------|
| 1 | 条件付きフォワーダー | `azure.internal` → `10.10.5.4`（Inbound Endpoint） |

> Spoke VNet にリンクした Private DNS Zone は、VM の NIC に対して A レコードを自動登録します。
> 例: `vm-spoke1-web.azure.internal` → `10.20.1.4`

---

## DNS Private Resolver のサブネット要件

DNS Private Resolver の各エンドポイントは **専用サブネット** を必要とします。

| エンドポイント | サブネット | CIDR | 備考 |
|--------------|----------|------|------|
| Inbound | `snet-dns-inbound` | 10.10.5.0/28 | 他リソースとの共有不可。最小 /28 |
| Outbound | `snet-dns-outbound` | 10.10.5.16/28 | 他リソースとの共有不可。最小 /28 |

> Inbound Endpoint の IP（通常 `10.10.5.4`）はサブネット内の最初の使用可能アドレスが自動割り当てされます。

---

## クラウド閉域内の名前解決パターン

VPN を経由しないクラウド内の閉域名前解決には、以下のパターンがあります。

### パターン 1: Azure 組み込み DNS（同一 VNet 内のみ）

同一 VNet 内の VM は、Azure 提供の DNS（`168.63.129.16`）により VM 名で自動的に解決されます。設定は不要です。

- **制約**: ピアリング先の VNet からは解決できない

### パターン 2: Azure Private DNS Zone（VNet 間対応）

Private DNS Zone を作成し、VNet Link で関連付けることで、複数 VNet 間での名前解決が可能になります。

```
┌─ Private DNS Zone: azure.internal ──────────────┐
│  vm-spoke1-web   → 10.20.1.4  (自動登録)        │
│  vm-spoke1-sql   → 10.20.2.4  (自動登録)        │
└──────────────────────────────────────────────────┘
         │ VNet Link (自動登録有効)     │ VNet Link (解決のみ)
         ▼                             ▼
    vnet-spoke1                    vnet-hub
```

| 設定 | 説明 |
|------|------|
| VNet Link（Registration 有効） | VM の A レコードを自動で登録・削除 |
| VNet Link（Registration 無効） | 解決のみ。レコードの自動登録はしない |

**制約**:
- 自動登録リンクは 1 ゾーンあたり最大 1000 VNet
- Private DNS Zone 名はグローバルに一意である必要はない（プライベート空間）

### パターン 3: Private DNS Zone + Private Endpoint

Azure PaaS サービス（SQL Database、Storage など）を Private Endpoint 経由でアクセスする場合、`privatelink.*.net` 形式の Private DNS Zone と連携します。

```
Private Endpoint (pep-spoke2-sql)
    ↓ A レコード自動登録
Private DNS Zone: privatelink.database.windows.net
    ↓ VNet Link
vnet-hub → 解決可能
```

本 HOL の Azure SQL Database はこのパターンを使用しています。

---

## ハイブリッド環境での名前解決シナリオ

`Setup-HybridDns.ps1` のオプション組み合わせにより、以下のシナリオに対応できます。

### 基本構成（オプションなし）

```powershell
.\Setup-HybridDns.ps1
```

| 方向 | 解決可能な名前 | 例 |
|------|--------------|-----|
| Hub → オンプレ | AD ドメイン名 | `app01.lab.local` → `10.0.1.5` |
| オンプレ → クラウド PaaS | Private Endpoint の FQDN | `sql-spoke2.database.windows.net` → PE の IP |

### Spoke VM ↔ オンプレ の名前解決を追加

```powershell
.\Setup-HybridDns.ps1 -LinkSpokeVnets
```

基本構成に加えて:

| 方向 | 解決可能な名前 | 例 |
|------|--------------|-----|
| Spoke → オンプレ | AD ドメイン名 | `db01.lab.local` → `10.0.2.4` |

> Spoke VNet に Forwarding Ruleset のリンクを追加することで、Spoke VM が Azure DNS 経由で `lab.local` を解決できるようになります。

### オンプレ → クラウド VM 名の解決を追加

```powershell
.\Setup-HybridDns.ps1 -EnableCloudVmResolution
```

基本構成に加えて:

| 方向 | 解決可能な名前 | 例 |
|------|--------------|-----|
| オンプレ → クラウド VM | VM ホスト名 | `vm-spoke1-web.azure.internal` → `10.20.1.4` |

> Private DNS Zone `azure.internal` に Spoke VNet を自動登録リンクし、DC01 に条件付きフォワーダーを追加します。

### フル構成（全オプション有効）

```powershell
.\Setup-HybridDns.ps1 -LinkSpokeVnets -EnableCloudVmResolution
```

すべての方向で名前解決が可能:

```
オンプレ ←──── lab.local ─────────── Hub / Spoke [1/3]
オンプレ ────► privatelink.*.net ──► クラウド PaaS [2/3]
オンプレ ────► azure.internal ────► クラウド VM  [3/3]
Spoke   ────► lab.local ──────────► オンプレ     [1/3 + -LinkSpokeVnets]
```

> **注意**: DNS は名前解決のみを提供します。実際の通信は VPN のルーティング（LGW addressPrefixes）と Firewall / NSG のアクセス制御に依存します。

---

## 重要なポイント

- **DNS Private Resolver のエンドポイントは専用サブネットが必要**。他のリソースとの共有は不可
- **Forwarding Ruleset は VNet Link が必要**。リンクしない VNet からは転送ルールが適用されない（`-LinkSpokeVnets` の意義）
- **条件付きフォワーダーは VPN 接続後に設定する**。VPN が未接続の状態では DNS クエリが到達しない
- **Private DNS Zone の自動登録は VM の NIC レコードのみ**。PaaS（App Service, ACA, AKS）は対象外で、それぞれの `privatelink.*` ゾーンが必要
- **Private Endpoint 用の `privatelink.*` ゾーンと VM 用のカスタムゾーンは別々に管理する**のが推奨
- **DNS は名前解決のみ**。通信の許可/拒否は Azure Firewall ポリシーや NSG で制御する（DNS 設定で細粒度のアクセス制御はできない）

---

## 参考

- [Azure DNS Private Resolver 概要](https://learn.microsoft.com/azure/dns/dns-private-resolver-overview)
- [Azure Private DNS Zone 概要](https://learn.microsoft.com/azure/dns/private-dns-overview)
- [Private DNS Zone の自動登録](https://learn.microsoft.com/azure/dns/private-dns-autoregistration)
- [ハイブリッド DNS の名前解決設計](https://learn.microsoft.com/azure/dns/private-resolver-hybrid-dns)
- [Private Endpoint の DNS 構成](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
- [Hub-Spoke での DNS 設計 (CAF)](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/private-link-and-dns-integration-at-scale)
- [VNet リンクと自動登録の制限事項](https://learn.microsoft.com/azure/dns/private-dns-virtual-network-links)
