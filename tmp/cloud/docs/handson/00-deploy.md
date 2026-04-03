# Phase 0: 環境デプロイ

## 目的

「Deploy to Azure」ボタンで PoC 環境全体を一括構築します。

## 前提条件

- Azure サブスクリプション（Owner 権限推奨）
- ブラウザ（Azure Portal にアクセス可能）

## 手順

### 1. Deploy to Azure ボタンをクリック

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/TODO)

### 2. パラメータを入力

| パラメータ | 既定値 | 説明 |
|-----------|--------|------|
| `location` | `japaneast` | デプロイリージョン |
| `adminUsername` | `azureadmin` | VM 管理者ユーザー名 |
| `adminPassword` | *(入力必須)* | VM 管理者パスワード（12 文字以上、複雑さ要件あり） |
| `deployFirewall` | `true` | Azure Firewall をデプロイするか |
| `deployVpnGateway` | `true` | VPN Gateway をデプロイするか |
| `deployBastion` | `true` | Azure Bastion をデプロイするか |

### 3. デプロイ完了を待機

デプロイには約 **60〜90 分** かかります（VPN Gateway のプロビジョニングが最も時間を要する）。

```text
Deploy to Azure ボタン
  │
  ├─ 1. リソースグループ作成 (rg-onprem, rg-hub, rg-spoke1〜4)
  ├─ 2. VNet × 6 + Peering
  ├─ 3. Azure Firewall + UDR
  ├─ 4. VPN Gateway × 2 + 接続  ← 30〜45 分
  ├─ 5. Azure Bastion
  ├─ 6. Log Analytics + Policy + Defender
  ├─ 7. Azure Migrate プロジェクト
  └─ 8. 疑似オンプレ VM (DC01, APP01, DB01) + セットアップスクリプト
```

### 4. デプロイ結果の確認

Azure Portal で以下のリソースグループが作成されていることを確認します。

| リソースグループ | 主なリソース |
|-----------------|-------------|
| `rg-onprem` | DC01, APP01, DB01, vnet-onprem, vgw-onprem |
| `rg-hub` | afw-hub, bas-hub, vgw-hub, log-hub, vnet-hub |
| `rg-spoke1` | vnet-spoke1（VM は Phase 5a でデプロイ） |
| `rg-spoke2` | vnet-spoke2（リソースは Phase 5b でデプロイ） |
| `rg-spoke3` | vnet-spoke3（リソースは Phase 5c でデプロイ） |
| `rg-spoke4` | vnet-spoke4（リソースは Phase 5d でデプロイ） |

## 次のステップ

→ [Phase 1: 現状確認](01-explore-onprem.md)
