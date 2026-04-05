# ExpressRoute によるオンプレ接続 — S2S VPN との比較と設定

## 概要

本 HOL では S2S VPN を使用していますが、本番環境では **ExpressRoute** による閉域網接続が推奨されるケースが多くあります。本ドキュメントでは、Hub 環境をExpressRoute 接続に切り替える場合の設計・設定・S2S VPN との違いをまとめます。

---

## S2S VPN と ExpressRoute の比較

| 項目 | S2S VPN | ExpressRoute |
|------|---------|-------------|
| 接続経路 | インターネット経由（IPsec 暗号化） | 閉域網（MPLS / キャリア網） |
| 帯域幅 | 最大 10 Gbps（SKU 依存） | 50 Mbps ～ 100 Gbps |
| レイテンシ | インターネット依存（不安定） | 低レイテンシ（SLA あり） |
| 暗号化 | IPsec で常時暗号化 | 既定では暗号化なし（MACsec / VPN over ER で対応可） |
| 冗長性 | Active-Active 構成で対応 | キャリア側で冗長回線が標準 |
| 導入期間 | 即日（数分でデプロイ） | 数週間〜数か月（キャリア契約が必要） |
| コスト | VPN Gateway SKU 料金のみ | 回線料金 + Gateway SKU + ピアリング料金 |
| SLA | 99.95%（Active-Active） | 99.95%（Standard） |
| Microsoft 365 / Dynamics 接続 | 不可 | Microsoft ピアリングで可能 |

---

## ExpressRoute 接続に必要な Azure リソース

### S2S VPN の場合（本 HOL）

```
rg-hub
  ├── vgw-hub              (VPN Gateway, SKU: VpnGw1)
  ├── lgw-onprem           (Local Network Gateway)
  └── cn-hub-to-onprem     (Connection, type: IPsec)
```

### ExpressRoute の場合

```
rg-hub
  ├── ergw-hub             (ExpressRoute Gateway, SKU: Standard/HighPerformance/UltraPerformance)
  ├── pip-ergw-hub         (Public IP for ER Gateway)
  └── cn-hub-to-onprem     (Connection, type: ExpressRoute)

※ Local Network Gateway は不要
※ ExpressRoute Circuit はキャリア/プロバイダー側が提供
```

### リソース比較

| リソース | S2S VPN | ExpressRoute | 備考 |
|---------|---------|-------------|------|
| VPN Gateway | `vgw-hub` | - | 不要（ER Gateway に置き換え） |
| ExpressRoute Gateway | - | `ergw-hub` | GatewaySubnet に配置 |
| Local Network Gateway | `lgw-onprem` | - | **不要**（ER は BGP で経路交換） |
| Connection | `cn-hub-to-onprem` (IPsec) | `cn-hub-to-onprem` (ExpressRoute) | type が異なる |
| ExpressRoute Circuit | - | キャリア提供 | Azure 側で参照のみ |

> **重要**: VPN Gateway と ExpressRoute Gateway は **同じ GatewaySubnet を共有できます**。共存構成（VPN + ER）も可能です。

---

## ExpressRoute の主要コンポーネント

### 1. ExpressRoute Circuit（回線）

キャリア / 接続プロバイダーが提供する閉域回線です。Azure 側では `Microsoft.Network/expressRouteCircuits` リソースとして管理します。

```
ExpressRoute Circuit
  ├── Service Provider: NTT Communications / Equinix / etc.
  ├── Peering Location: Tokyo / Osaka
  ├── Bandwidth: 50 Mbps ～ 100 Gbps
  └── Peering:
      ├── Azure Private Peering  (VNet 接続用, 必須)
      └── Microsoft Peering       (Microsoft 365 / PaaS 接続用, オプション)
```

### 2. ExpressRoute Gateway（Azure 側）

VNet の `GatewaySubnet` にデプロイする Gateway リソースです。

| SKU | 最大接続数 | 最大帯域幅 | FastPath |
|-----|----------|----------|----------|
| Standard | 4 | 1 Gbps | 非対応 |
| HighPerformance | 4 | 2 Gbps | 非対応 |
| UltraPerformance | 16 | 10 Gbps | 対応 |
| ErGw1Az ～ ErGw3Az | 4 ～ 16 | 1 ～ 10 Gbps | ErGw3Az で対応 |

### 3. Connection（接続リソース）

ExpressRoute Circuit と ExpressRoute Gateway を関連付けます。

---

## Bicep テンプレート例

### ExpressRoute Gateway

```bicep
// CAF 命名: ergw-hub
resource expressRouteGateway 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = {
  name: 'ergw-hub'
  location: location
  tags: defaultTags
  properties: {
    gatewayType: 'ExpressRoute'        // VPN ではなく ExpressRoute
    sku: {
      name: 'Standard'
      tier: 'Standard'
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          subnet: {
            id: gatewaySubnetId          // VPN GW と同じ GatewaySubnet を使用
          }
          publicIPAddress: {
            id: pipExpressRouteGateway.id
          }
        }
      }
    ]
  }
}
```

### ExpressRoute Connection

```bicep
// ExpressRoute Circuit の Authorization Key を使用して接続
resource expressRouteConnection 'Microsoft.Network/connections@2024-01-01' = {
  name: 'cn-hub-to-onprem'
  location: location
  tags: defaultTags
  properties: {
    connectionType: 'ExpressRoute'     // IPsec ではなく ExpressRoute
    virtualNetworkGateway1: {
      id: expressRouteGateway.id
    }
    peer: {
      id: expressRouteCircuitId         // キャリアから提供される Circuit の ID
    }
    authorizationKey: authorizationKey  // 別サブスクリプションの場合に必要
  }
}
```

---

## ルーティングの違い

### S2S VPN

- **スタティックルート**: Local Network Gateway の `addressPrefixes` で手動定義
- **BGP**: オプションで有効化可能

### ExpressRoute

- **BGP が必須**: オンプレ側ルーター / キャリア CE ルーターと BGP ピアリングで経路交換
- Local Network Gateway は不要（BGP で動的に学習）
- オンプレ側のアドレス空間を明示的に定義する必要がない

```
S2S VPN:  LGW addressPrefixes: ["10.0.0.0/16"]  ← 手動定義
ER:       BGP で 10.0.0.0/16 を自動学習           ← 動的
```

---

## 本 HOL を ExpressRoute に切り替える場合の変更点

| 変更箇所 | S2S VPN（現在） | ExpressRoute |
|---------|---------------|-------------|
| `rg-hub` の Gateway | `vgw-hub` (VpnGw1) | `ergw-hub` (Standard) |
| `rg-hub` の LGW | `lgw-onprem` — 削除 | 不要 |
| `rg-hub` の Connection | type: IPsec + sharedKey | type: ExpressRoute + Circuit ID |
| `rg-onprem` の Gateway | `vgw-onprem` — 削除 | 不要（キャリア側が担当） |
| `rg-onprem` の LGW | `lgw-hub` — 削除 | 不要 |
| `rg-onprem` の Connection | `cn-onprem-to-hub` — 削除 | 不要 |
| Bicep テンプレート | `vpn-connection.bicep` / `vpn-connection-hub.bicep` | `expressroute-gateway.bicep` / `expressroute-connection.bicep` |
| 双方向設定 | 必要（Azure 同士のため） | **不要**（ER は BGP で自動） |

---

## 共存構成（VPN + ExpressRoute）

ExpressRoute と S2S VPN を同一 Hub VNet で共存させることも可能です。

```
rg-hub / GatewaySubnet
  ├── ergw-hub     (ExpressRoute Gateway)  ← メイン経路
  └── vgw-hub      (VPN Gateway)           ← フェイルオーバー経路
```

- ExpressRoute が優先（より具体的なルート / BGP weight）
- ExpressRoute 障害時に VPN へ自動フェイルオーバー
- **条件**: VPN Gateway は Route-Based かつ BGP 有効が必要

---

## 参考

- [ExpressRoute の概要](https://learn.microsoft.com/azure/expressroute/expressroute-introduction)
- [ExpressRoute の回線とピアリング](https://learn.microsoft.com/azure/expressroute/expressroute-circuit-peerings)
- [ExpressRoute Gateway の構成](https://learn.microsoft.com/azure/expressroute/expressroute-about-virtual-network-gateways)
- [VPN と ExpressRoute の共存](https://learn.microsoft.com/azure/expressroute/expressroute-howto-coexist-resource-manager)
- [ExpressRoute の暗号化 (MACsec)](https://learn.microsoft.com/azure/expressroute/expressroute-about-encryption)
