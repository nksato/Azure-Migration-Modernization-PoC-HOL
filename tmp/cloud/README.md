# Azure Migration & Modernization PoC ハンズオン

## 環境デプロイ

### Step 1: 移行先クラウド環境（Hub & Spoke）

Hub VNet（Firewall / VPN GW / Bastion / 管理サービス）+ Spoke VNet x 4 をデプロイします。

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2F%3Cgithub-owner%3E%2F%3Crepo-name%3E%2Fmain%2Finfra%2Fcloud%2Fazuredeploy.json)

> 上記ボタンを使う場合は、リンク内の `<github-owner>/<repo-name>` を自身の fork / mirror に置き換えてください。

### Step 2: 移行元オンプレ環境（複数 VM）

疑似オンプレ環境（複数の VM: DC01 / WEB01 / SQL01 / YOURMA01）をデプロイし、VPN で Hub に接続します。

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/TODO_ONPREM)

> **デプロイ順序**: 必ず Step 1（クラウド） → Step 2（オンプレ）の順でデプロイしてください。  
> Step 2 は Hub VNet の VPN Gateway に接続するため、Step 1 の完了が前提です。

## 概要

オンプレミスから Azure への移行・モダナイズの一連の流れを体験できるハンズオンコンテンツです。  
疑似オンプレ環境（複数 VM）を構築し、4 つの移行パターンを比較できます。

## 対象者

- Azure を提案するパートナー
- Azure への移行を検討しているお客様（インフラ経験者）

## シナリオ

| Phase | タイトル | 内容 |
|-------|---------|------|
| 0 | [環境デプロイ](docs/handson/00-deploy.md) | Deploy to Azure で全環境を構築 |
| 1 | [現状確認](docs/handson/01-explore-onprem.md) | 疑似オンプレ環境（複数 VM）のアプリ動作確認 |
| 2 | [Arc 接続](docs/handson/02-arc-onboard.md) | オンプレ VM を Azure Arc に登録 |
| 3 | [ハイブリッド管理](docs/handson/03-hybrid-mgmt.md) | Policy / Monitor / Defender / Update Manager |
| 4 | [移行アセスメント](docs/handson/04-assessment.md) | Azure Migrate アプライアンス（オンプレ内）でアセスメント |
| 5a | [Rehost](docs/handson/05a-rehost.md) | Spoke1: VM を Lift & Shift |
| 5b | [DB PaaS 化](docs/handson/05b-db-paas.md) | Spoke2: VM + Azure SQL |
| 5c | [コンテナ化](docs/handson/05c-containerize.md) | Spoke3: Container Apps + Azure SQL |
| 5d | [フル PaaS](docs/handson/05d-full-paas.md) | Spoke4: App Service + Azure SQL |
| 6 | [比較・まとめ](docs/handson/06-compare.md) | 移行パターンの比較検討 |

## 移行パターン比較

| Spoke | パターン | AP 基盤 | DB 基盤 | コスト/月 | 主要ツール |
|-------|---------|---------|---------|----------|--------|
| Spoke1 | Rehost | Azure VM | Azure VM | ~$90 | Copilot 移行 Agent + Migrate |
| Spoke2 | DB PaaS 化 | Azure VM | Azure SQL | ~$42 | Copilot App Mod + DMS |
| Spoke3 | コンテナ化 | Container Apps | Azure SQL | ~$17 | Copilot App Mod + Docker |
| Spoke4 | フル PaaS | App Service | Azure SQL | ~$25 | Copilot App Mod |

## アーキテクチャ

詳細は [アーキテクチャ設計書](docs/architecture-design.md) を参照。

```text
  On-Prem VNet                          Hub VNet                 Spoke VNets
  10.0.0.0/16                           10.10.0.0/16
 ┌───────────────────────────────┐     ┌──────────────┐   ┌── Spoke1 (10.20.0.0/16) Rehost
 │ DC01 / WEB01 / SQL01 / YOURMA01│     │ Azure FW     │   │   VM + VM
 │ (複数 VM で疑似オンプレを構成)  │S2S  │ (Basic)      │   │
 ├───────────────────────────────┤VPN  │              │   ├── Spoke2 (10.21.0.0/16) DB PaaS
 │ Migrate Appliance: YOURMA01    ├──► │ VPN Gateway  │   │   VM + Azure SQL
 └───────────────────────────────┘     │              │◄──┤
                                       │ Bastion      │   ├── Spoke3 (10.22.0.0/16) Container
                                       │ DNS Resolver │   │   Container Apps + Azure SQL
                                       │ Private DNS  │   │
                                       └──────────────┘   └── Spoke4 (10.23.0.0/16) Full PaaS
                                                             App Service + Azure SQL
```

## コスト

### クラウド環境（Step 1）

| サービス | 月額概算 |
|---------|--------|
| Azure Firewall Basic | ~$300 |
| VPN Gateway (Hub 側 VpnGw1AZ) | ~$150 |
| Azure Bastion Basic | ~$140 |
| DNS Private Resolver | ~$180 |
| Log Analytics / Policy / Defender | ~$30 |
| **クラウド基盤合計** | **~$800** |

### オンプレ環境（Step 2）

| サービス | 月額概算 |
|---------|--------|
| 疑似オンプレ VM x 4（DC01 / WEB01 / SQL01 / YOURMA01） | TBD |
| VPN Gateway (On-Prem 側 VpnGw1) | ~$150 |
| **オンプレ基盤合計** | **TBD** |

> 注: 疑似オンプレ環境は Nested Hyper-V ホスト + Nested VM ではなく、複数の Azure VM で構成します。

### Spoke リソース（ハンズオン時に追加）

| Spoke | 月額概算 |
|-------|--------|
| Spoke 全部合計 | +~$174 |

### コスト最適化

| 状態 | 月額概算 |
|------|--------|
| 全常時稼働 | ~$1,230 + TBD |
| 利用時のみ起動 | ~$100-150 + TBD |

## 前提条件

- Azure サブスクリプション（Owner 権限推奨）
- GitHub Copilot ライセンス（Phase 5b, 5c, 5d で使用）

## クイックスタート

1. **Step 1** の「Deploy to Azure」ボタンをクリックし、クラウド環境をデプロイ（約 30-45 分）
2. Step 1 の完了を確認後、**Step 2** の「Deploy to Azure」ボタンをクリックし、オンプレ環境（複数 VM）をデプロイ（約 30-45 分）
3. 全環境が利用可能になるまで約 60-90 分待機
4. [Phase 1](docs/handson/01-explore-onprem.md) から順にハンズオンを開始