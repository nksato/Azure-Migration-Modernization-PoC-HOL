# Azure Migration & Modernization PoC ハンズオン - アーキテクチャ設計書

## 1. 概要

### 1.1 目的

Azure への移行・モダナイズの一連の流れを、パートナーやお客様のインフラ経験者が体験できるハンズオンコンテンツ。  
「Deploy to Azure」ボタン一発で **疑似オンプレ環境（Azure 上の複数 VM）** を含む全環境が構築され、以下のシナリオを段階的に体験できる。

### 1.2 シナリオ全体像

```text
Phase 0: デプロイ          → Deploy to Azure で全環境構築
Phase 1: 現状確認          → 疑似オンプレ環境（複数 VM）のアプリ動作確認
Phase 2: Arc 接続          → オンプレ VM を Azure Arc に登録
Phase 3: ハイブリッド管理    → Policy / Monitor / Defender / Update Manager
Phase 4: 移行アセスメント    → Azure Migrate アプライアンス（オンプレ内）でアセスメント
Phase 5a: Rehost           → Spoke1 へ VM を Lift & Shift（Azure Migrate）
Phase 5b: DB PaaS 化       → Spoke2 へ VM + Azure SQL（DB のみ PaaS）
Phase 5c: コンテナ化       → Spoke3 へ Container Apps + Azure SQL
Phase 5d: フル PaaS 化     → Spoke4 へ App Service + Azure SQL
Phase 6: モダナイズ         → GitHub Copilot App Modernization でコード変換
```

### 1.3 移行パターン比較

| Spoke | パターン | AP 基盤 | DB 基盤 | 主要ツール |
|-------|---------|---------|---------|-----------|
| Spoke1 | Rehost（Lift & Shift） | Azure VM (IIS) | Azure VM (SQL Server) | Azure Copilot 移行エージェント + Azure Migrate |
| Spoke2 | DB PaaS 化 | Azure VM (IIS) | Azure SQL Database | Copilot App Mod + DMS |
| Spoke3 | コンテナ化 | Azure Container Apps | Azure SQL Database | Copilot App Mod + Docker |
| Spoke4 | フル PaaS 化 | Azure App Service | Azure SQL Database | Copilot App Mod |

---

## 2. ネットワーク構成

### 2.1 全体トポロジ

```text
                                         ┌──── Spoke1 VNet (10.20.0.0/16) ── Rehost (VM+VM)
                                         │
On-Prem VNet ────S2S VPN────Hub VNet ────┼──── Spoke2 VNet (10.21.0.0/16) ── VM + Azure SQL
10.0.0.0/16      (GW-GW)    10.10.0.0/16│
                                         ├──── Spoke3 VNet (10.22.0.0/16) ── Container Apps + Azure SQL
┌─────────────────────────────────────┐  │
│ 疑似オンプレ (On-Prem VNet)          │  └──── Spoke4 VNet (10.23.0.0/16) ── App Service + Azure SQL
│  DC01 / WEB01 / SQL01 / YOURMA01     │
│  ※Nested Hyper-V ではなく複数 VM     │        Hub VNet
└─────────────────────────────────────┘        ┌───────────────────────┐
              S2S VPN                           │ Azure Firewall Basic  │
                                                │ VPN Gateway (VpnGw1)  │
                                                │ Azure Bastion (Basic) │
                                                │ Log Analytics WS      │
                                                └───────────────────────┘
```

### 2.2 VNet / サブネット設計

#### On-Prem VNet

| サブネット | CIDR | 用途 |
|----------|------|------|
| snet-onprem-vms | 10.0.1.0/24 | 疑似オンプレ VM（DC01/WEB01/SQL01/YOURMA01） |
| GatewaySubnet | 10.0.255.0/27 | VPN Gateway |

> 注: 旧設計の `snet-yourhost`（Hyper-V ホスト用）は使用しません。

#### Hub VNet

| サブネット | CIDR | 用途 |
|----------|------|------|
| AzureFirewallSubnet | 10.10.1.0/26 | Azure Firewall |
| AzureBastionSubnet | 10.10.2.0/26 | Azure Bastion |
| GatewaySubnet | 10.10.255.0/27 | VPN Gateway |
| snet-management | 10.10.3.0/24 | 管理 VM 等（予備） |

#### Spoke1 VNet（Rehost）

| サブネット | CIDR | 用途 |
|----------|------|------|
| snet-web | 10.20.1.0/24 | 移行先 Web VM |
| snet-db | 10.20.2.0/24 | 移行先 SQL VM |

#### Spoke2 VNet（DB PaaS 化）

| サブネット | CIDR | 用途 |
|----------|------|------|
| snet-web | 10.21.1.0/24 | Web VM (IIS) |
| snet-pep | 10.21.2.0/24 | Private Endpoint (Azure SQL) |

#### Spoke3 VNet（コンテナ化）

| サブネット | CIDR | 用途 |
|----------|------|------|
| snet-aca | 10.22.1.0/23 | Azure Container Apps Environment |
| snet-pep | 10.22.3.0/24 | Private Endpoint (Azure SQL) |

#### Spoke4 VNet（フル PaaS）

| サブネット | CIDR | 用途 |
|----------|------|------|
| snet-appservice | 10.23.1.0/24 | App Service VNet Integration |
| snet-pep | 10.23.2.0/24 | Private Endpoint (Azure SQL) |

### 2.3 ルーティング

- **Hub ↔ 各 Spoke**: VNet Peering（Hub 側でゲートウェイ転送有効、Spoke 側でリモートゲートウェイ使用）
- **On-Prem ↔ Hub**: VPN Gateway 同士の VNet-to-VNet 接続で S2S VPN を模擬
- **各 Spoke → Internet**: Azure Firewall 経由（UDR で 0.0.0.0/0 → Firewall Private IP）
- **On-Prem ↔ Spoke**: Hub の VPN Gateway → Firewall → Peering → Spoke
- **Spoke 間通信**: Hub Firewall 経由（各 Spoke の UDR で他 Spoke アドレス → Firewall）

---

## 3. 疑似オンプレ環境（複数 VM）

> 重要: 疑似オンプレ環境は **Hyper-V ホスト VM + Nested VM ではなく、Azure 上の複数 VM（4台）** で構成します。

### 3.1 VM 構成（4台）

| VM 名 | 役割 | OS | vCPU | RAM | ディスク(目安) |
|-------|------|-----|------|-----|---------------|
| **DC01** | AD DS / DNS | Windows Server 2022 | 2 | 4 GB | 40 GB |
| **WEB01** | IIS + .NET Framework 4.8 アプリ | Windows Server 2019 | 2 | 4 GB | 40 GB |
| **SQL01** | SQL Server 2019 Developer | Windows Server 2019 | 2 | 8 GB | 60 GB |
| **YOURMA01** | Azure Migrate Appliance | Windows Server 2022 | 4 | 8 GB | 80 GB |
| | | | | **合計** | **220 GB** |

> 上記はハンズオン用途の目安です。実際のサイズは Bicep/パラメータに従います。

### 3.2 ネットワーク（On-Prem VNet 内）

- 4台すべてを On-Prem VNet の `snet-onprem-vms (10.0.1.0/24)` に配置します。
- On-Prem ↔ Hub は S2S VPN（VNet-to-VNet）で接続します。

> 旧設計のような NAT（192.168.100.0/24）前提はありません。

### 3.3 サンプルアプリケーション

| 項目 | 内容 |
|------|------|
| **フレームワーク** | ASP.NET MVC 5 (.NET Framework 4.8) |
| **アプリ種別** | 在庫管理システム（Inventory Management） |
| **ホスト** | IIS 10 on WEB01 |
| **DB** | SQL Server 2019 Developer Edition on SQL01 |
| **認証** | Windows 認証（AD DS 連携） |
| **機能** | 商品一覧 / 登録 / 編集 / 削除 (CRUD) + 簡易レポート |

> **選定理由**: .NET Framework 4.8 + SQL Server は典型的なオンプレ構成であり、  
> GitHub Copilot App Modernization で .NET 8 への変換を体験するのに最適。  
> また、コンテナ化シナリオ (Spoke3) では Docker イメージ化の体験も可能。

### 3.4 Active Directory 構成

| 項目 | 値 |
|------|-----|
| ドメイン名 | contoso.local |
| フォレスト機能レベル | Windows Server 2016 |
| DNS | AD 統合 DNS |
| OU 構成 | OU=Servers, OU=ServiceAccounts |
| サービスアカウント | svc-webapp (Web アプリ用), svc-sqlserver (SQL 用) |

### 3.5 Azure Migrate アプライアンス（YOURMA01）

| 項目 | 値 |
|------|-----|
| 配置場所 | On-Prem VNet 内（YOURMA01） |
| 検出方法 | VM/サーバー（DC01/WEB01/SQL01）を検出・評価（詳細はハンズオン手順に従う） |
| 検出対象 | DC01, WEB01, SQL01 |
| 評価種別 | Azure VM 評価 + Azure SQL 評価 + Azure App Service 評価 |

> **配置理由**: 実環境ではアプライアンスはお客様のオンプレ内に配置する。  
> 疑似オンプレ VNet 内に配置することで、移行フローの前提（オンプレ側にアプライアンスがある）を再現する。

---

## 4. Hub VNet（共有サービス）

### 4.1 Azure Firewall

| 項目 | 値 |
|------|-----|
| SKU | Basic |
| パブリック IP | 1 個（Standard SKU） |
| 月額概算 | ~$300 |

**ルール設計**:

| ルール種別 | 名前 | ソース | 宛先 | プロトコル/ポート |
|-----------|------|--------|------|-----------------|
| Network | OnPrem-to-Spokes | 10.0.0.0/16 | 10.20-23.0.0/16 | Any |
| Network | Spokes-to-OnPrem | 10.20-23.0.0/16 | 10.0.0.0/16 | Any |
| Network | Spoke-to-Spoke | 10.20-23.0.0/16 | 10.20-23.0.0/16 | Any |
| Application | Allow-WindowsUpdate | * | WindowsUpdate | HTTPS |
| Application | Allow-AzureServices | * | AzureCloud | HTTPS |
| Application | Allow-ArcEndpoints | 10.0.0.0/16 | *.guestconfiguration.azure.com 等 | HTTPS |

### 4.2 VPN Gateway

| 項目 | Hub 側 | On-Prem 側 |
|------|--------|-----------|
| SKU | VpnGw1 | VpnGw1 |
| 種別 | VNet-to-VNet | VNet-to-VNet |
| 共有キー | 自動生成（Bicep パラメータ） |
| 月額概算 | ~$150 | ~$150 |

### 4.3 Azure Bastion

| 項目 | 値 |
|------|-----|
| SKU | Basic |
| 接続先 | （例）オンプレ側 VM / Spoke 側 VM など（ハンズオン手順に従う） |
| 月額概算 | ~$140 |

> 旧設計の「Bastion → vm-yourhost（Hyper-Vホスト）→ Nested VM 操作」前提はありません。

### 4.4 アプリへのブラウザアクセス方式

全フェーズを通じて **Bastion 経由の RDP** でアプリにブラウザアクセスする。

| 環境 | アクセスフロー |
|------|---------------|
| **移行前** (On-Prem VNet) | Bastion → WEB01 に RDP → ブラウザ → `http://localhost`（または手順記載のURL） |
| **Spoke1** (Rehost VM) | Bastion → vm-spoke1-web に RDP → ブラウザ → `http://localhost` |
| **Spoke2** (VM + Azure SQL) | Bastion → vm-spoke2-web に RDP → ブラウザ → `http://localhost` |
| **Spoke3** (Container Apps) | Container Apps のパブリック Ingress URL に直接アクセス |
| **Spoke4** (App Service) | `https://app-spoke4-xxx.azurewebsites.net` に直接アクセス |

---

## 5. Spoke VNet 構成

初期デプロイ時は **VNet とサブネットのみ作成**。リソースは各 Phase で参加者が手動またはスクリプトでデプロイ。

### 5.1 Spoke1 — Rehost（Lift & Shift）

| サービス | 用途 | SKU | 月額概算 |
|---------|------|-----|---------|
| Azure VM (Web) | 移行先 Web サーバー | Standard_B2s | ~$30 |
| Azure VM (SQL) | 移行先 SQL Server | Standard_B2ms | ~$60 |

**移行方法**: Azure Migrate: Server Migration（**エージェントベース**）

1. WEB01 / SQL01 に **Mobility Service Agent** をインストール
2. Azure Migrate でレプリケーションを開始
3. テスト移行を実施（Spoke1 VNet 内に移行先 VM が自動作成される）
4. テスト移行の動作確認後、本番移行（カットオーバー）を実行

```text
WEB01 (On-Prem VM)
  └─ Mobility Service Agent インストール
  └─ レプリケーション → テスト移行 → カットオーバー
  └─→ vm-spoke1-web (Azure VM in Spoke1)

SQL01 (On-Prem VM)
  └─ Mobility Service Agent インストール
  └─ レプリケーション → テスト移行 → カットオーバー
  └─→ vm-spoke1-sql (Azure VM in Spoke1)
```

> **エージェントベースを選択した理由**:
> - Mobility Service Agent のインストール体験ができる
> - レプリケーション→テスト移行→カットオーバーの一連のフローを体験
> - 実環境でも物理サーバーや他ハイパーバイザーからの移行はエージェントベースが必要

**ブラウザ確認**: Bastion → vm-spoke1-web に RDP → ブラウザで `http://localhost` にアクセス

### 5.2 Spoke2 — DB のみ PaaS 化

| サービス | 用途 | SKU | 月額概算 |
|---------|------|-----|---------|
| Azure VM (Web) | Web サーバー (IIS) | Standard_B2s | ~$30 |
| Azure SQL Database | DB (PaaS) | Basic (5 DTU) | ~$5 |
| Private Endpoint | Azure SQL への閉域接続 | - | ~$7 |

**移行方法**: GitHub Copilot App Modernization + DMS

1. **DB 移行**: DMS で SQL Server 2019 → Azure SQL Database に移行（スキーマ + データ）
2. **アプリ変更**: GitHub Copilot App Modernization で接続先を Azure SQL に変更
   - 接続文字列の変更（SQL Server → Azure SQL の接続文字列）
   - Windows 認証 → SQL 認証 or Microsoft Entra 認証への変更
   - Entity Framework の接続プロバイダー更新
3. Azure VM (IIS) にアプリの変更版をデプロイ

```text
SQL01 ──DMS──→ sqldb-spoke2 (Azure SQL Database, Private Endpoint 経由)
WEB01 (ASP.NET MVC 5) ──Copilot App Mod──→ 接続先変更版 ──Deploy──→ vm-spoke2-web (Azure VM / IIS)
```

> **ポイント**: コード自体は .NET Framework 4.8 のまま。DB の接続先だけを Azure SQL に変更する  
> 「最小限のコード変更 + DB PaaS 化」パターンを体験。

**ブラウザ確認**: Bastion → vm-spoke2-web に RDP → ブラウザで `http://localhost` にアクセス

### 5.3 Spoke3 — コンテナ化 + DB PaaS

| サービス | 用途 | SKU | 月額概算 |
|---------|------|-----|---------|
| Azure Container Apps | コンテナ化した Web アプリ | Consumption | ~$0 (従量課金) |
| Azure Container Registry | コンテナイメージ保管 | Basic | ~$5 |
| Azure SQL Database | DB (PaaS) | Basic (5 DTU) | ~$5 |
| Private Endpoint | Azure SQL への閉域接続 | - | ~$7 |

**モダナイズ方法**: GitHub Copilot App Modernization + Docker + DMS

1. **DB 移行**: DMS で SQL Server 2019 → Azure SQL Database に移��
2. **コード変換**: GitHub Copilot App Modernization で .NET Framework 4.8 → .NET 8 に変換
3. **コンテナ化**: Dockerfile を作成しマルチステージビルド
4. **デプロイ**: ACR にイメージプッシュ → Container Apps にデプロイ
5. **接続設定**: Container Apps の環境変数で Azure SQL の接続文字列を設定

```text
SQL01 ──DMS──→ sqldb-spoke3 (Azure SQL Database)
WEB01 (ASP.NET MVC 5) ──Copilot App Mod──→ .NET 8 ──Docker──→ ACR ──→ Container Apps
```

> **ポイント**: コード変換 + コンテナ化の 2 段階を体験。  
> Container Apps の Consumption プランでコスト最小化。

**ブラウザ確認**: Container Apps のパブリック Ingress URL に直接アクセス

### 5.4 Spoke4 — フル PaaS 化

| サービス | 用途 | SKU | 月額概算 |
|---------|------|-----|---------|
| App Service | Web アプリ (.NET 8) | B1 (Basic) | ~$13 |
| App Service Plan | ホスティングプラン | B1 | (上記に含む) |
| Azure SQL Database | DB (PaaS) | Basic (5 DTU) | ~$5 |
| Private Endpoint | Azure SQL への閉域接続 | - | ~$7 |

**モダナイズ方法**: GitHub Copilot App Modernization + DMS

1. **DB 移行**: DMS で SQL Server 2019 → Azure SQL Database に移行
2. **コード変換**: GitHub Copilot App Modernization で .NET Framework 4.8 → .NET 8 に変換
3. **デプロイ**: App Service にデプロイ（az webapp deploy または GitHub Actions）
4. **ネットワーク**: VNet Integration 設定 + Private Endpoint 経由で Azure SQL に接続

```text
SQL01 ──DMS──→ sqldb-spoke4 (Azure SQL Database)
WEB01 (ASP.NET MVC 5) ──Copilot App Mod──→ .NET 8 ──Deploy──→ App Service
```

> **ポイント**: コード変換 + PaaS デプロイの王道パターン。  
> VNet Integration + Private Endpoint で閉域接続も体験。

**ブラウザ確認**: `https://app-spoke4-xxx.azurewebsites.net` に直接アクセス

### 5.5 Spoke 間の比較まとめ

| 観点 | Spoke1 (Rehost) | Spoke2 (DB PaaS) | Spoke3 (Container) | Spoke4 (Full PaaS) |
|------|-----------------|-------------------|--------------------|--------------------|
| 主要ツール | Copilot 移行 Agent + Migrate | Copilot App Mod + DMS | Copilot App Mod + Docker | Copilot App Mod |
| AP 変更 | なし | 接続文字列変更 | .NET 8 変換 + Docker化 | .NET 8 変換 |
| DB 変更 | なし | PaaS化 (DMS) | PaaS化 (DMS) | PaaS化 (DMS) |
| 運用負荷 | 高（OS管理あり） | 中（Web VM の管理あり） | 低 | 低 |
| スケーラビリティ | 低 | 低 | 高 | 中〜高 |
| コスト（月額） | ~$90 | ~$42 | ~$17 | ~$25 |
| 移行難易度 | 低 | 低〜中 | 高 | 中〜高 |
| 推奨シナリオ | 緊急移行 | DB だけ先に PaaS 化 | マイクロサービス化 | Web アプリの PaaS 化 |
| ブラウザ確認 | Bastion→VM RDP | Bastion→VM RDP | パブリック URL | パブリック URL |

---

## 6. 管理・ガバナンス

### 6.1 Azure Policy（事前適用）

| ポリシー | 効果 | 説明 |
|---------|------|------|
| Allowed locations | Deny | 許可リージョンを制限（Japan East / Japan West） |
| Allowed VM SKUs | Deny | 許可する VM サイズを制限 |
| Require tag on resource group | Deny | RG に Environment タグを強制 |
| Inherit tag from RG (Environment) | Modify | RG のタグをリソースに継承 |
| Storage accounts should disable public access | **Audit** | ストレージのパブリックアクセスを監査 |
| Storage accounts should use HTTPS | Audit | ストレージの HTTPS 通信を監査 |
| SQL servers should have auditing enabled | Audit | SQL Server の監査有効化を監査 |
| Public network access on Azure SQL Database should be disabled | **Audit** | Azure SQL のパブリックアクセスを監査 |
| Management ports should be closed | **Audit** | VM の管理ポート開放を監査 |
| Azure Key Vault should disable public network access | **Audit** | Key Vault のパブリックアクセスを監査 |
| App Service apps should disable public network access | **Audit** | App Service のパブリックアクセスを監査 |
| Azure Container Registry should not allow unrestricted network access | **Audit** | ACR のパブリックアクセスを監査 |
| Container Apps should only be accessible over HTTPS | **Audit** | Container Apps の HTTPS 強制を監査 |
| Microsoft Defender for Cloud should be enabled | **AuditIfNotExists** | Defender 有効化を監査 |

### 6.2 Azure Monitor / Log Analytics

| 項目 | 値 |
|------|-----|
| Log Analytics Workspace | 1 つ（Hub VNet 内、全 Spoke 共通） |
| 保持期間 | 30 日（無料範囲） |
| VM Insights | 有効化（Arc 登録後） |
| データ収集ルール | Windows Event Log + Performance Counter |
| Container Insights | 有効化（Spoke3 Container Apps 用） |

### 6.3 Microsoft Defender for Cloud

| プラン | 対象 |
|--------|------|
| Defender for Servers P1 | VM / Arc-enabled Servers |
| Defender for SQL | SQL Server VM / Arc-enabled SQL / Azure SQL |
| Defender for App Service | Spoke4 App Service |
| Defender for Containers | Spoke3 Container Apps |

### 6.4 Azure Update Manager

- Arc 登録後の **On-Prem VNet 上の VM** に対して定期パッチ評価を有効化
- メンテナンスウィンドウの設定例を含む

---

## 7. Azure Arc 構成（Phase 2 で実施）

### 7.1 Arc-enabled Servers

| 対象 | 登録方法 | 備考 |
|------|---------|------|
| DC01（On-Prem VM） | Connected Machine Agent 手動インストール | そのまま動作 |
| WEB01（On-Prem VM） | Connected Machine Agent 手動インストール | そのまま動作 |
| SQL01（On-Prem VM） | Connected Machine Agent 手動インストール | そのまま動作 |

> 旧設計の「Nested VM は Azure VM ではないため〜」という注記は不要です。  
> 本ハンズオンでは疑似オンプレを Azure 上の VM で構成します。

### 7.2 Arc-enabled SQL Server

| 対象 | エディション |
|------|------------|
| SQL01 上の SQL Server 2019 | Developer |

- SQL Server 用 Azure Extension for SQL Server をインストール
- SQL Best Practices Assessment を有効化
- Defender for SQL を有効化

---

## 8. Azure Migrate（Phase 4-5 で実施）

### 8.1 アセスメント

| 項目 | 内容 |
|------|------|
| プロジェクト | Azure Migrate プロジェクト（Bicep で事前作成） |
| アプライアンス | YOURMA01（On-Prem VNet 内） |
| 検出対象 | DC01, WEB01, SQL01 |

**アセスメント種別**:

| 評価種別 | 評価先 | 対応 Spoke |
|---------|--------|-----------|
| Azure VM 評価 | IaaS 移行先のサイジング | Spoke1, Spoke2 |
| Azure SQL 評価 | Azure SQL Database 互換性 | Spoke2, Spoke3, Spoke4 |
| Azure App Service 評価 | App Service 互換性 | Spoke4 |

### 8.2 Azure Copilot 移行エージェント（Phase 5a で使用）

Azure Migrate ポータルから Copilot 移行エージェントを起動し、自然言語で移行計画・分析を実施する。

| 機能 | 内容 | ハンズオンでの体験 |
|------|------|---------------|
| 移行戦略の分析 | Lift & Shift vs モダナイズのトレードオフ説明 | Spoke1 vs Spoke2-4 の比較材料に |
| インベントリ分析 | 検出 VM の要約・ OS 情報・サポート状況 | アプライアンスが検出した VM を分析 |
| ビジネスケース / ROI | 移行によるコスト削減効果の算出 | お客様への提案資料に活用可 |
| 準備状況評価 | 評価結果の解���・阻害要因の特定 | Azure VM / SQL 評価の解説を AI が実施 |
| ランディングゾーン | ターゲット環境構成の自動生成 | Hub & Spoke 構成の生成を体験 |

> **前提条件**: Azure Copilot がテナントで有効化されていること。  
> エージェント（プレビュー）が Azure Copilot で有効になっていること。

### 8.3 移行実行（Phase 5a: Spoke1 Rehost）

Copilot 移行エージェントの分析結果を踏まえ、Azure Migrate ポータルで実際の移行を実行する。

| 移行元 | 移行先 | 方式 |
|--------|--------|------|
| WEB01（On-Prem VM） | vm-spoke1-web (Spoke1) | Azure Migrate: Server Migration |
| SQL01（On-Prem VM） | vm-spoke1-sql (Spoke1) | Azure Migrate: Server Migration |

### 8.4 DB 移行（Phase 5b-d: Spoke2/3/4）

| 移行元 | 移行先 | ツール |
|--------|--------|--------|
| SQL01 (SQL Server 2019) | Azure SQL Database | Azure Database Migration Service (DMS) |

> DMS はオンラインまたはオフライン移行を選択可能。ハンズオンではオフライン移行を推奨。

---

## 9. GitHub Copilot App Modernization（Phase 5b-d で実施）

### 9.1 概要

GitHub Copilot App Modernization を **Spoke2 / Spoke3 / Spoke4 の全パターン** で使用する。  
各 Spoke で変換の深さが異なるため、段階的にモダナイズの効果を体験できる。

| 項目 | 内容 |
|------|------|
| 移行元 | ASP.NET MVC 5 (.NET Framework 4.8) |
| 利用シナリオ | Spoke2（接続先変更）、Spoke3（.NET 8 + コンテナ化）、Spoke4（.NET 8 + PaaS） |

### 9.2 Spoke2 向け: DB 接続先変更（最小変更）

Copilot App Modernization で以下の変更を実施（フレームワークは .NET Framework 4.8 のまま）:

1. `Web.config` の接続文字列を Azure SQL Database 向けに変更
2. Windows 認証 → SQL 認証 or Microsoft Entra 認証への変更
3. Entity Framework の接続設定更新
4. 変更後のアプリを VM (IIS) にデプロイ

> **体験ポイント**: 「コードはほぼそのまま、DB だけ PaaS 化」の手軽さを実感

### 9.3 Spoke3 向け: .NET 8 変換 + コンテナ化

Copilot App Modernization で .NET 8 への変換 + Docker 化:

1. GitHub Copilot App Modernization で .NET Framework 4.8 → .NET 8 に変換
2. 変換結果のレビュー・修正
3. Dockerfile 作成（マルチステージビルド）
4. コンテナイメージをビルド → ACR にプッシュ
5. Container Apps にデプロイ
6. Azure SQL Database の接続文字列を環境変数で設定
7. 動作確認（パブリック URL）

> **体験ポイント**: フレームワーク変換 + コンテナ化のフルモダナイズ

### 9.4 Spoke4 向け: .NET 8 変換 + App Service デプロイ

Copilot App Modernization で .NET 8 への変換 + PaaS デプロイ:

1. GitHub Copilot App Modernization で .NET Framework 4.8 → .NET 8 に変換  
   （Spoke3 で変換済みのコードを再利用可能）
2. App Service にデプロイ（az webapp deploy または GitHub Actions）
3. VNet Integration 設定
4. Azure SQL Database に Private Endpoint 経由で接続
5. 動作確認（`https://app-spoke4-xxx.azurewebsites.net`）

> **体験ポイント**: PaaS デプロイの王道パターン。VNet Integration による閉域接続も体験

### 9.5 Copilot App Modernization の段階的な活用まとめ

| Spoke | Copilot の活用レベル | 変換内容 |
|-------|---------------------|----------|
| Spoke2 | 軽微（接続先変更） | 接続文字列・認証方式の変更のみ |
| Spoke3 | フル（コード変換） | .NET 4.8 → .NET 8 + Dockerfile 生成 |
| Spoke4 | フル（コード変換） | .NET 4.8 → .NET 8（Spoke3 のコード再利用可） |

---

## 10. コスト見積もり

### 10.1 月額概算（基盤 = 常時稼働）

| カテゴリ | サービス | 月額概算 |
|---------|---------|---------|
| コンピュート | 疑似オンプレ VM x 4（DC01/WEB01/SQL01/YOURMA01） | TBD |
| ネットワーク | Azure Firewall Basic | $300 |
| ネットワーク | VPN Gateway x 2 (VpnGw1) | $300 |
| ネットワーク | Azure Bastion Basic | $140 |
| モニタリング | Log Analytics (無料範囲内) | $0 |
| セキュリティ | Defender for Servers P1 x 3 | $15 |
| セキュリティ | Defender for SQL x 1 | $15 |
| **基盤合計** | | **~$770/月 + TBD** |

> 注: 旧設計の「Hyper-V ホスト VM (D8s_v5) $280」は削除（Nested Hyper-V を使用しないため）。

### 10.2 Spoke リソース（Phase 5-6 でデプロイ時に追加）

| Spoke | サービス | 月額概算 |
|-------|---------|---------|
| Spoke1 | VM x 2 (B2s + B2ms) | ~$90 |
| Spoke2 | VM (B2s) + Azure SQL (Basic) + PE | ~$42 |
| Spoke3 | Container Apps (従量) + ACR (Basic) + Azure SQL + PE | ~$17 |
| Spoke4 | App Service (B1) + Azure SQL (Basic) + PE | ~$25 |
| **Spoke 全部合計** | | **~$174/月** |

### 10.3 コスト最適化策

| 対策 | 効果 |
|------|------|
| 疑似オンプレ VM の Auto-shutdown（夜間・週末） | コンピュートコスト削減 |
| Azure Firewall をパラメータで ON/OFF 可能に | 非実施時に ~$300 節約 |
| VPN Gateway をパラメータで ON/OFF 可能に | 非実施時に ~$300 節約 |
| Bastion をパラメータで ON/OFF 可能に | 非実施時に ~$140 節約 |
| Spoke リソースは手順内でデプロイ/削除 | 不要時は $0 |
| **実質コスト（利用時のみ起動）** | **~$100-150/月 + TBD** |

> Firewall / VPN GW / Bastion は Bicep パラメータで作成有無を制御。  
> ハンズオン前に作成、終了後に削除するスクリプトも用意。

---

## 11. Deploy to Azure 構成

### 11.1 Bicep モジュール構成

```text
infra/
├── main.bicep                        # エントリポイント
├── main.bicepparam                   # パラメータファイル
├── modules/
│   ├── network/
│   │   ├── onprem-vnet.bicep         # 疑似オンプレ VNet
│   │   ├── hub-vnet.bicep            # Hub VNet
│   │   ├── spoke-vnets.bicep         # Spoke VNet x 4（パラメータ化）
│   │   ├── peering.bicep             # VNet Peering (Hub ↔ 各 Spoke)
│   │   ├── vpn-gateway.bicep         # VPN Gateway (両側)
│   │   ├── firewall.bicep            # Azure Firewall Basic + ルール
│   │   ├── bastion.bicep             # Azure Bastion
│   │   └── route-table.bicep         # UDR (各 Spoke 用)
│   ├── compute/
│   │   └── （疑似オンプレ VM 定義）  # DC01/WEB01/SQL01/YOURMA01
│   ├── governance/
│   │   ├── log-analytics.bicep       # Log Analytics Workspace
│   │   ├── policy.bicep              # Azure Policy 割り当て
│   │   └── defender.bicep            # Microsoft Defender for Cloud
│   ├── migration/
│   │   └── migrate-project.bicep     # Azure Migrate プロジェクト
│   └── spoke-resources/
│       ├── spoke1-rehost.bicep       # Spoke1 用リソース（VM x 2）
│       ├── spoke2-db-paas.bicep      # Spoke2 用（VM + Azure SQL + PE）
│       ├── spoke3-container.bicep    # Spoke3 用（ACA + ACR + Azure SQL + PE）
│       └── spoke4-full-paas.bicep    # Spoke4 用（App Service + Azure SQL + PE）
└── scripts/
    └── （必要に応じて）             # 旧: Hyper-V/Nested VM 作成スクリプトは前提にしない
```

> 注: 旧設計の `vm-yourhost.bicep` や `setup-yourhost*.ps1` は Nested Hyper-V 前提のため、本設計書では前提としません。

### 11.2 Deploy to Azure ボタン

```markdown
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/...)
```

**パラメータ**:

| パラメータ | 型 | 既定値 | 説明 |
|-----------|-----|--------|------|
| location | string | japaneast | デプロイリージョン |
| adminUsername | string | yourAdmin | 管理者ユーザー名 |
| adminPassword | securestring | - | 管理者パスワード |
| deployFirewall | bool | true | Azure Firewall をデプロイするか |
| deployVpnGateway | bool | true | VPN Gateway をデプロイするか |
| deployBastion | bool | true | Bastion をデプロイするか |
| （onpremVmSize 等） | string | - | 疑似オンプレ VM のサイズ（テンプレートに従う） |

### 11.3 デプロイフロー

```text
Deploy to Azure ボタン
  │
  ├─ 1. リソースグループ作成
  ├─ 2. VNet x 6 (OnPrem + Hub + Spoke x 4) + Peering
  ├─ 3. Azure Firewall + UDR（deployFirewall=true の場合）
  ├─ 4. VPN Gateway x 2 + 接続（deployVpnGateway=true の場合）  ← 30-45分
  ├─ 5. Bastion（deployBastion=true の場合）
  ├─ 6. Log Analytics + Policy + Defender
  ├─ 7. Azure Migrate プロジェクト
  └─ 8. 疑似オンプレ VM x 4（DC01/WEB01/SQL01/YOURMA01）をデプロイ
```

> 全環境が利用可能になるまで約 **60-90 分**を想定（VPN Gateway デプロイ + VM セットアップ並行）。

---

## 12. リポジトリ構成

```text
hackathon/
├── README.md                           # プロジェクト概要 + Deploy to Azure ボタン
├── docs/
│   ├── architecture-design.md          # 本ドキュメント
│   ├── handson/
│   │   ├── 00-deploy.md                # Phase 0: 環境デプロイ
│   │   ├── 01-explore-onprem.md        # Phase 1: 現状確認（On-Prem VM 操作）
│   │   ├── 02-arc-onboard.md           # Phase 2: Arc 接続
│   │   ├── 03-hybrid-mgmt.md           # Phase 3: ハイブリッド管理
│   │   ├── 04-assessment.md            # Phase 4: Azure Migrate アセスメント
│   │   ├── 05a-rehost.md               # Phase 5a: Spoke1 Rehost
│   │   ├── 05b-db-paas.md              # Phase 5b: Spoke2 DB PaaS 化
│   │   ├── 05c-containerize.md         # Phase 5c: Spoke3 コンテナ化
│   │   ├── 05d-full-paas.md            # Phase 5d: Spoke4 フル PaaS 化
│   │   └── 06-compare.md               # Phase 6: 移行パターン比較・まとめ
│   └── images/                         # アーキテクチャ図等
├── infra/                              # Bicep テンプレート
└── ...
```

---

## 13. 注意事項・制約

### 13.1 疑似オンプレ（複数 VM）の前提

- 疑似オンプレは **4台の Azure VM**（DC01/WEB01/SQL01/YOURMA01）で構成する
- On-Prem VNet 内の VM は、Hub/Spoke と **S2S VPN** で接続される

### 13.2 VPN Gateway デプロイ時間

- VPN Gateway のプロビジョニングには 30～45 分かかる
- Deploy to Azure 実行後、全環境が利用可能になるまで約 60-90 分を想定

### 13.3 GitHub Copilot App Modernization

- GitHub Copilot の利用には GitHub Copilot ライセンスが必要
- App Modernization 機能は GitHub のプレビュー機能の場合がある（時期により利用条件が異なる）
- Spoke3（コンテナ化）と Spoke4（フル PaaS）で利用

### 13.4 Spoke リソースのデプロイタイミング

- Spoke 内のリソース（VM / App Service / Container Apps / Azure SQL 等）は初期デプロイに含まない
- 各 Phase のハンズオン手順内で参加者がデプロイする（Bicep モジュールまたはスクリプトを用意）
- 全 Spoke を試す必要はなく、目的に応じて選択可能
