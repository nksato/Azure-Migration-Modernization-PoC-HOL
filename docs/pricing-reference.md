# Azure 参考価格一覧

本ハンズオン環境をすべてデプロイした場合の Azure リソース月額コスト概算です。

> **注意**
>
> - 価格は **Japan East (東日本)** リージョン、**従量課金 (PAYG)** の概算です（2026 年 4 月時点）
> - 実際のコストはリージョン別の最新価格、データ転送量、稼働時間により変動します
> - 正確な見積もりには [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) をご利用ください
> - **PoC / ハンズオン環境のため、使い終わったらリソースグループごと削除してください**

---

## 全体サマリー

| 環境 | 月額 (USD) | 備考 |
|---|---:|---|
| 疑似オンプレ (`rg-onprem`) | ~$492 | VM 3 台 + Bastion + NAT GW |
| ネットワーク (VPN Gateway) | ~$365 | VPN Gateway 2 台 (OnPrem + Hub) |
| クラウド基盤 (`rg-hub`) | ~$382 | Firewall + Bastion + DNS Resolver + Log Analytics |
| Spoke1: Rehost | ~$107 | VM 2 台 |
| Spoke2: DB PaaS 化 | ~$60 | VM 1 台 + Azure SQL Basic |
| Spoke3: コンテナ化 | ~$10 | ACR Basic + Azure SQL Basic (※1) |
| Spoke4: フル PaaS 化 | ~$18 | App Service B1 + Azure SQL Basic |
| **合計** | **~$1,434/月** | |
| **日本円換算 ($1=¥150)** | **~¥215,000/月** | |

> ※1 Container Apps Environment は Consumption プランではリクエスト分のみ課金。常時起動でなければ月額数ドル程度

---

## 1. 疑似オンプレ環境 (`rg-onprem`) — ~$492/月

`infra/onprem/main.bicep` で定義されるリソース。

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **vm-onprem-ad** (DC01) | Standard_D2s_v3 (2vCPU/8GB), Windows Server 2022 | ~$137 |
| **vm-onprem-sql** (DB01) | Standard_D2s_v3 (2vCPU/8GB), SQL Server 2019 Dev※ | ~$137 |
| **vm-onprem-web** (APP01) | Standard_D2s_v3 (2vCPU/8GB), Windows Server 2019 | ~$137 |
| OS Disk × 3 | StandardSSD_LRS 128GB (E10) × 3 | ~$29 |
| Data Disk × 1 (SQL 用) | StandardSSD_LRS 128GB (E10) | ~$10 |
| **bas-onprem** | Azure Bastion Basic | ~$139 |
| **ng-onprem** | NAT Gateway Standard | ~$33 |
| Public IP × 2 | Standard Static (Bastion + NAT GW) | ~$7 |
| VNet / NSG / NIC | — | $0 |

> ※ SQL Server Developer エディションはライセンス無料 (開発/テスト用途)

---

## 2. ネットワーク (VPN Gateway) — ~$365/月

`infra/network/main.bicep` で定義されるリソース。

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **vgw-onprem** | VPN Gateway VpnGw1 | ~$182 |
| **vpngw-hub** | VPN Gateway VpnGw1AZ | ~$182 |
| Public IP × 2 | Standard Static | ~$7 |
| Local Network Gateway × 2 | — | $0 |
| VPN Connection × 2 | S2S | ~$1 |

> VPN Gateway はデプロイに 30〜45 分かかり、停止しても継続課金されます。不要時は削除してください。

---

## 3. クラウド基盤 (`rg-hub`) — ~$382/月

`infra/cloud/main.bicep` で定義される Hub リソース。

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **afw-hub** | Azure Firewall Basic | ~$219 |
| **bas-hub** | Azure Bastion Basic | ~$139 |
| **dnspr-hub** | DNS Private Resolver (2 endpoint) | ~$14 |
| **log-hub** | Log Analytics (保持 30 日) | ~$3 |
| Public IP × 3 | Standard Static (FW × 2 + Bastion) | ~$10 |
| VNet / Peering / Route Table | — | $0 |
| Azure Policy / Defender for Cloud | Free 〜 Standard (VM のみ) | ~$0 |

---

## 4. Spoke1: Rehost (`rg-spoke1`) — ~$107/月

`infra/cloud/modules/spoke-resources/spoke1-rehost.bicep` で定義。

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **vm-spoke1-web** | Standard_B2s (2vCPU/4GB), Windows Server 2022 | ~$50 |
| **vm-spoke1-sql** | Standard_B2ms (2vCPU/8GB), SQL Server 2022 Dev | ~$57 |
| OS Disk × 2 | StandardSSD_LRS 128GB | ~$19 |
| NIC × 2 | — | $0 |

---

## 5. Spoke2: DB PaaS 化 (`rg-spoke2`) — ~$60/月

`infra/cloud/modules/spoke-resources/spoke2-db-paas.bicep` で定義。

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **vm-spoke2-web** | Standard_B2s (2vCPU/4GB), Windows Server 2022 | ~$50 |
| **sqldb-spoke2** | Azure SQL Database Basic (5 DTU) | ~$5 |
| Private Endpoint + DNS Zone | — | ~$7 |
| OS Disk | StandardSSD_LRS 128GB | ~$10 |

---

## 6. Spoke3: コンテナ化 (`rg-spoke3`) — ~$10/月

`infra/cloud/modules/spoke-resources/spoke3-container.bicep` で定義。

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **cae-spoke3** | Container Apps Environment (Consumption) | ~$0 |
| **crspoke3** | Azure Container Registry Basic | ~$5 |
| **sqldb-spoke3** | Azure SQL Database Basic (5 DTU) | ~$5 |
| Private Endpoint + DNS Zone | — | ~$7 |

> Container Apps は Consumption プランのため、アクティブなコンテナがなければ課金はほぼゼロ

---

## 7. Spoke4: フル PaaS 化 (`rg-spoke4`) — ~$18/月

`infra/cloud/modules/spoke-resources/spoke4-full-paas.bicep` で定義。

| リソース | SKU / スペック | 月額 (USD) |
|---|---|---:|
| **asp-spoke4** | App Service Plan B1 (1vCPU/1.75GB) | ~$13 |
| **app-spoke4** | App Service (.NET 8.0) | $0 (Plan に含む) |
| **sqldb-spoke4** | Azure SQL Database Basic (5 DTU) | ~$5 |
| Private Endpoint + DNS Zone | — | ~$7 |

---

## コスト削減のヒント

### ハンズオン中の節約

| 方法 | 削減額 | 備考 |
|---|---|---|
| **不使用時に VM を停止**（割り当て解除） | VM コンピューティング費用（全 VM で ~$568/月）がゼロ | ディスクと常時課金リソースのみ残る |
| **Bastion を一時デプロイ**にする | ~$278/月 (2 台分) | 接続が必要な時だけデプロイ → 終わったら削除 |
| **VPN Gateway を不要時に削除** | ~$365/月 | 再作成に 30〜45 分かかる点に注意 |

### 最も効率的な使い方

1. **ハンズオン当日のみデプロイ** → 終了後にリソースグループを削除
2. 環境を 1 日（8 時間）使用した場合の概算: **~$16/日 (~¥2,400/日)**
3. 週末 2 日間のハンズオンなら: **~$32 (~¥4,800)**

---

## 参考リンク

- [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)
- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
- [VM サイズ一覧 (Dv3/Dsv3)](https://learn.microsoft.com/azure/virtual-machines/dv3-dsv3-series)
- [Azure SQL Database 価格](https://azure.microsoft.com/pricing/details/azure-sql-database/single/)
- [Azure Firewall 価格](https://azure.microsoft.com/pricing/details/azure-firewall/)
