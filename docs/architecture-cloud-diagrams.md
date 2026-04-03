# クラウド移行 HOL - アーキテクチャ図

## 1. 全体ネットワーク構成

```mermaid
flowchart TB
    subgraph onprem["OnPrem VNet 10.0.0.0/16"]
        dc[DC01<br/>AD/DNS]
        dbsrc[DB01<br/>SQL Server]
        appsrc[APP01<br/>IIS/Web]
        onpremvpn[VPN Gateway]
    end

    subgraph hub["Hub VNet 10.10.0.0/16"]
        hubvpn[VPN Gateway]
        fw[Azure Firewall]
        bastion[Azure Bastion]
        dns[DNS Private Resolver]
        law[Log Analytics]
        migrate[Azure Migrate]
    end

    subgraph s1["Spoke1 10.20.0.0/16<br/>05a Rehost"]
        s1web[Web VM]
        s1db[DB VM]
    end

    subgraph s2["Spoke2 10.21.0.0/16<br/>05b DB PaaS"]
        s2web[Web VM]
        s2db[(Azure SQL)]
    end

    subgraph s3["Spoke3 10.22.0.0/16<br/>05c Container"]
        s3app[Container Apps]
        s3db[(Azure SQL)]
    end

    subgraph s4["Spoke4 10.23.0.0/16<br/>05d Full PaaS"]
        s4app[App Service]
        s4db[(Azure SQL)]
    end

    onpremvpn -- "S2S VPN" --> hubvpn
    hubvpn --- fw
    fw --- s1web & s2web & s3app & s4app
    bastion -.-> s1web & s2web
    migrate -.-> appsrc
    hub --- dns
```

## 2. 移行パターン比較フロー

```mermaid
flowchart LR
    SRC[移行元\nAPP01 / DB01] --> A[05a Rehost\nVM + VM]
    SRC --> B[05b DB PaaS 化\nVM + Azure SQL]
    SRC --> C[05c コンテナ化\nContainer Apps + Azure SQL]
    SRC --> D[05d フル PaaS 化\nApp Service + Azure SQL]
```

## 3. ハンズオンの流れ

```mermaid
flowchart TD
    P0[00. クラウド基盤デプロイ] --> P1[01. 移行元確認]
    P1 --> P2[02. Azure Arc 登録]
    P2 --> P3[03. ハイブリッド管理]
    P3 --> P4[04. アセスメント]
    P4 --> P5A[05a Rehost]
    P4 --> P5B[05b DB PaaS 化]
    P4 --> P5C[05c コンテナ化]
    P4 --> P5D[05d フル PaaS 化]
    P5A --> P6[06. 比較・まとめ]
    P5B --> P6
    P5C --> P6
    P5D --> P6
```
