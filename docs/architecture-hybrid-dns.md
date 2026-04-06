# ハイブリッド DNS 設計 — Azure DNS Private Resolver を中心とした名前解決

## 概要

本 HOL では、疑似オンプレ環境（`rg-onprem`）とクラウド Hub 環境（`rg-hub`）の間で **Azure DNS Private Resolver** を中心にした双方向 DNS 転送を構成しています。VPN 接続だけでは名前解決ができないため、DNS 転送設定が必要です。

本ドキュメントでは、ハイブリッド DNS の設計思想、構成要素、および Azure 閉域内での名前解決パターンをまとめます。

---

## 全体像

```
疑似オンプレ (10.0.0.0/16)                    クラウド / Hub (10.10.0.0/16)
┌─────────────────────┐                      ┌──────────────────────────────┐
│  DC01 (10.0.1.4)    │                      │  DNS Private Resolver        │
│  ┌────────────────┐ │   VPN (S2S)          │  ┌────────────┐             │
│  │ DNS Server     │◄├──────────────────────├──┤ Outbound   │             │
│  │                │ │  lab.local の         │  │ Endpoint   │             │
│  │ 条件付き       │ │  クエリを転送         │  └────────────┘             │
│  │ フォワーダー   │─├──────────────────────├─►┌────────────┐             │
│  │                │ │  privatelink.*.net の  │  │ Inbound    │             │
│  └────────────────┘ │  クエリを転送         │  │ Endpoint   │             │
│                     │                      │  │ 10.10.5.4  │             │
└─────────────────────┘                      │  └─────┬──────┘             │
                                             │        │                    │
                                             │  ┌─────▼──────────────────┐ │
                                             │  │ Private DNS Zone       │ │
                                             │  │ privatelink.           │ │
                                             │  │   database.windows.net │ │
                                             │  └────────────────────────┘ │
                                             └──────────────────────────────┘
```

---

## DNS 転送の方向と構成要素

| 方向 | 転送元 | 転送先 | 対象ゾーン | 仕組み |
|------|--------|--------|-----------|--------|
| クラウド → オンプレ | DNS Private Resolver（Outbound Endpoint） | DC01（`10.0.1.4:53`） | `lab.local` | DNS Forwarding Ruleset |
| オンプレ → クラウド | DC01（条件付きフォワーダー） | DNS Private Resolver（Inbound Endpoint `10.10.5.4`） | `privatelink.database.windows.net` | Windows DNS 条件付きフォワーダー |

---

## 必要なリソース

### Azure 側（rg-hub）

| # | リソース名 | リソースタイプ | 役割 |
|---|-----------|--------------|------|
| 1 | `dnspr-hub` | DNS Private Resolver | 名前解決の中核。Inbound / Outbound Endpoint を持つ |
| 2 | Inbound Endpoint | DNS Private Resolver Endpoint | オンプレからの DNS クエリを受け付ける（`10.10.5.4`） |
| 3 | Outbound Endpoint | DNS Private Resolver Endpoint | オンプレ DNS への転送クエリを送出する |
| 4 | `dnsrs-hub` | DNS Forwarding Ruleset | Outbound Endpoint に紐付く転送ルールの集合 |
| 5 | `rule-lab-local` | Forwarding Rule | `lab.local.` → DC01（`10.0.1.4:53`）への転送ルール |
| 6 | `link-vnet-hub` | VNet Link（Ruleset） | Forwarding Ruleset を Hub VNet にリンク |

### オンプレ側（DC01）

| # | 設定 | 内容 |
|---|------|------|
| 1 | 条件付きフォワーダー | `privatelink.database.windows.net` → `10.10.5.4`（Inbound Endpoint） |

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

## ハイブリッド環境でのフル名前解決（発展）

本 HOL の構成に加え、クラウド側の VM 名もオンプレから解決したい場合の追加設定:

```
オンプレ (lab.local)                        クラウド (azure.internal)
┌──────────────────┐                      ┌──────────────────────────────┐
│  DC01            │                      │  DNS Private Resolver        │
│  DNS Server      │                      │  ┌──────────┐               │
│                  │◄─── Forwarding ──────│──┤ Outbound │               │
│  lab.local       │     Rule             │  └──────────┘               │
│  (A レコード)     │                      │                              │
│                  │                      │  ┌──────────┐               │
│  条件付き FW ────│──────────────────────│─►│ Inbound  │               │
│  azure.internal  │                      │  │ 10.10.5.4│               │
│  privatelink.*   │                      │  └────┬─────┘               │
└──────────────────┘                      │       │                      │
                                          │  ┌────▼─────────────────┐   │
                                          │  │ Private DNS Zone     │   │
                                          │  │ azure.internal       │   │
                                          │  │  vm-spoke1-web → IP  │   │
                                          │  └──────────────────────┘   │
                                          └──────────────────────────────┘
```

追加で必要な設定:

| # | 設定 | 内容 |
|---|------|------|
| 1 | Private DNS Zone | `azure.internal` を作成 |
| 2 | VNet Link（自動登録） | 対象 VNet に Registration 有効でリンク |
| 3 | DC01 条件付きフォワーダー | `azure.internal` → `10.10.5.4` を追加 |

> Forwarding Ruleset への追加は不要です。Inbound Endpoint が Private DNS Zone を直接解決します。

---

## 重要なポイント

- **DNS Private Resolver のエンドポイントは専用サブネットが必要**。他のリソースとの共有は不可
- **Forwarding Ruleset は VNet Link が必要**。リンクしない VNet からは転送ルールが適用されない
- **条件付きフォワーダーは VPN 接続後に設定する**。VPN が未接続の状態では DNS クエリが到達しない
- **Private DNS Zone の自動登録を活用すると VM の追加・削除時に A レコードが自動管理される**
- **Private Endpoint 用の `privatelink.*` ゾーンと VM 用のカスタムゾーンは別々に管理する**のが推奨

---

## 参考

- [Azure DNS Private Resolver 概要](https://learn.microsoft.com/azure/dns/dns-private-resolver-overview)
- [Azure Private DNS Zone 概要](https://learn.microsoft.com/azure/dns/private-dns-overview)
- [Private DNS Zone の自動登録](https://learn.microsoft.com/azure/dns/private-dns-autoregistration)
- [ハイブリッド DNS の名前解決設計](https://learn.microsoft.com/azure/dns/private-resolver-hybrid-dns)
- [Private Endpoint の DNS 構成](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
- [Hub-Spoke での DNS 設計 (CAF)](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/private-link-and-dns-integration-at-scale)
- [VNet リンクと自動登録の制限事項](https://learn.microsoft.com/azure/dns/private-dns-virtual-network-links)
