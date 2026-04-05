# Project Guidelines

## 疑似オンプレ環境の技術スタック

本プロジェクトの疑似オンプレ環境（`rg-onprem`）は以下の技術スタックで構成される。

- **アプリケーション**: ASP.NET MVC (.NET Framework 4.8) — IIS 上でホスト（`APP01`）
- **データベース**: SQL Server 2019 Developer Edition（`DB01`）

移行シナリオ（Spoke1〜4）では、このオンプレ構成を前提にリホスト・DB PaaS 化・コンテナ化・フル PaaS 化を行う。

## Azure リソース命名規則

本プロジェクトの Azure リソースは [CAF 推奨の省略形](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations) に準拠する。

### リソースグループ

| リソースグループ名 | 用途 |
|-------------------|------|
| `rg-onprem` | 疑似オンプレ環境（DC01, APP01, DB01） |
| `rg-hub` | 共有サービス（Firewall, Bastion, VPN Gateway, Log Analytics） |
| `rg-spoke1` | Rehost（Lift & Shift）移行先 |
| `rg-spoke2` | DB PaaS 化移行先 |
| `rg-spoke3` | コンテナ化移行先 |
| `rg-spoke4` | フル PaaS 化移行先 |

### VNet

| VNet 名 | CIDR | リソースグループ |
|---------|------|-----------------|
| `vnet-onprem` | 10.0.0.0/16 | rg-onprem |
| `vnet-hub` | 10.10.0.0/16 | rg-hub |
| `vnet-spoke1` | 10.20.0.0/16 | rg-spoke1 |
| `vnet-spoke2` | 10.21.0.0/16 | rg-spoke2 |
| `vnet-spoke3` | 10.22.0.0/16 | rg-spoke3 |
| `vnet-spoke4` | 10.23.0.0/16 | rg-spoke4 |

### サブネット（プレフィックス `snet-`）

CAF 推奨: `snet`

| サブネット名 | 例外（Azure 予約名） |
|-------------|---------------------|
| `snet-onprem` | - |
| `snet-web` | - |
| `snet-db` | - |
| `snet-pep` | Private Endpoint 用 |
| `snet-aca` | Container Apps Environment 用 |
| `snet-appservice` | App Service VNet Integration 用 |
| `snet-management` | 管理 VM 等（予備） |
| `GatewaySubnet` | Azure 予約名（変更不可） |
| `AzureFirewallSubnet` | Azure 予約名（変更不可） |
| `AzureBastionSubnet` | Azure 予約名（変更不可） |

### 疑似オンプレ VM（rg-onprem 内）

| VM 名 | 役割 | OS |
|-------|------|-----|
| `DC01` | AD DS / DNS | Windows Server 2022 |
| `APP01` | IIS + .NET Framework 4.8 アプリ | Windows Server 2019 |
| `DB01` | SQL Server 2019 Developer | Windows Server 2019 |

### Hub リソース（rg-hub 内）

| リソース名 | CAF 省略形 | 用途 |
|-----------|-----------|------|
| `afw-hub` | `afw` | Azure Firewall Basic |
| `afwp-hub` | `afwp` | Firewall Policy |
| `bas-hub` | `bas` | Azure Bastion |
| `vgw-hub` | `vgw` | VPN Gateway (Hub 側) |
| `vgw-onprem` | `vgw` | VPN Gateway (OnPrem 側) |
| `log-hub` | `log` | Log Analytics Workspace |
| `dnspr-hub` | `dnspr` | DNS Private Resolver |
| `dnsrs-hub` | `dnsrs` | DNS Forwarding Ruleset |

### Spoke リソース

| リソース名パターン | CAF 省略形 | 用途 |
|-------------------|-----------|------|
| `vm-spoke{N}-web` | `vm` | 移行先 Web VM |
| `vm-spoke{N}-sql` | `vm` | 移行先 SQL VM |
| `sql-spoke{N}` | `sql` | Azure SQL Database サーバー |
| `sqldb-spoke{N}` | `sqldb` | Azure SQL Database |
| `pep-spoke{N}-sql` | `pep` | Private Endpoint (Azure SQL) |
| `ca-spoke3` | `ca` | Container Apps |
| `cae-spoke3` | `cae` | Container Apps Environment |
| `cr-spoke3` | `cr` | Container Registry |
| `app-spoke4` | `app` | App Service |
| `asp-spoke4` | `asp` | App Service Plan |

### その他共通リソース

| リソース名パターン | CAF 省略形 | 用途 |
|-------------------|-----------|------|
| `nsg-{サブネット名}` | `nsg` | Network Security Group |
| `rt-{サブネット名}` | `rt` | Route Table |
| `pip-{リソース名}` | `pip` | Public IP Address |
| `nic-{VM名}` | `nic` | Network Interface |
| `migr-project` | `migr` | Azure Migrate プロジェクト |

## タグ付けルール

すべてのリソースグループとリソースに以下のタグを付与する。

### 必須タグ

| タグキー | 値の例 | 説明 |
|---------|--------|------|
| `Environment` | `PoC` | 環境種別（PoC 固定） |
| `Project` | `Migration-Handson` | プロジェクト名 |
| `SecurityControl` | `Ignore` | セキュリティポリシー制御除外用 |

### SecurityControl タグの用途

- `SecurityControl: Ignore` タグは、ハンズオン用 PoC 環境であることを示す
- Defender for Cloud やセキュリティポリシーの推奨事項を抑制するために使用
- **本番環境には絶対に使用しない**

### タグ付け方針

- リソースグループに `Environment` タグを Deny ポリシーで強制
- `Inherit tag from RG (Environment)` の Modify ポリシーでリソースに自動継承
- Bicep テンプレートでは `tags` パラメータにデフォルトタグを定義する

```bicep
// Bicep でのタグ定義例
var defaultTags = {
  Environment: 'PoC'
  Project: 'Migration-Handson'
  SecurityControl: 'Ignore'
}
```

## 命名規則の参考資料

- [Abbreviation recommendations for Azure resources](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations)
- [Define your naming convention](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)
- [Naming rules and restrictions for Azure resources](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules)
