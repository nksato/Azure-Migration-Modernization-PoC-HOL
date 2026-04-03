# 疑似オンプレ環境アーキテクチャ図

## 1. 全体構成図

```mermaid
flowchart TB
    subgraph OnPremVNet[OnPrem VNet 10.0.0.0/16]
        subgraph ServerSubnet[ServerSubnet 10.0.1.0/24]
            DC[DC01<br/>Active Directory / DNS]
            DB[DB01<br/>SQL Server]
            APP[APP01<br/>IIS + ASP.NET]
        end

        subgraph BastionSubnet[AzureBastionSubnet 10.0.254.0/26]
            Bastion[Azure Bastion]
        end

        subgraph GatewaySubnet[GatewaySubnet 10.0.255.0/27]
            VPNGW[VPN Gateway]
        end
    end

    DC --- DB
    DB --- APP
    Bastion --> DC
    Bastion --> DB
    Bastion --> APP
    VPNGW -. 将来接続 .- ServerSubnet
```

## 2. デプロイ & セットアップ フロー

```mermaid
flowchart TD
    A[00. インフラ デプロイ] --> B[DC01: AD / DNS 構成]
    B --> C[DB01 / APP01 をドメイン参加]
    C --> D[DB01: SQL Server セットアップ]
    D --> E[APP01: Parts Unlimited デプロイ]
    E --> F[02. 動作確認 / 疎通確認]
    F --> G[移行 HOL の移行元環境として利用]
```

## 3. 接続イメージ

```mermaid
flowchart LR
    User[受講者] --> Portal[Azure Portal]
    Portal --> Bastion[Azure Bastion]
    Bastion --> APP01[APP01]
    Bastion --> DB01[DB01]
    Bastion --> DC01[DC01]

    APP01 -->|SQL 接続| DB01
    APP01 -->|認証 / DNS| DC01
```

## 4. 補足

- **インバウンドの管理アクセスは Bastion 経由に集約**します
- **APP01 → DB01 / DC01** の内部通信で 3 層構成を成立させます
- 将来的には **VPN Gateway** を介して Hub VNet や移行先環境と接続する前提です
