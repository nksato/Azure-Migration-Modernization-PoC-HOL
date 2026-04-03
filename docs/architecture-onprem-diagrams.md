# 疑似オンプレ環境アーキテクチャ図

## 1. 全体構成図

```mermaid
architecture-beta
    group onprem(cloud)[OnPrem VNet 10.0.0.0/16]

    group serverSub(server)[ServerSubnet 10.0.1.0/24] in onprem
    group bastionSub(cloud)[AzureBastionSubnet 10.0.254.0/26] in onprem
    group gatewaySub(internet)[GatewaySubnet 10.0.255.0/27] in onprem

    service dc(server)[DC01 Active Directory / DNS] in serverSub
    service db(database)[DB01 SQL Server] in serverSub
    service app(server)[APP01 IIS + ASP.NET] in serverSub
    service bastion(server)[Azure Bastion] in bastionSub
    service vpngw(internet)[VPN Gateway] in gatewaySub

    dc:R -- L:db
    db:R -- L:app
    bastion:B --> T:dc
    bastion:B --> T:db
    bastion:B --> T:app
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
