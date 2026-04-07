# Azure 同士の S2S VPN — 双方向設定が必要な理由

## 概要

本 HOL では疑似オンプレ環境（`rg-onprem`）とクラウド Hub 環境（`rg-hub`）の間を **Azure VPN Gateway 同士の S2S 接続** で結んでいます。Azure VPN Gateway 同士を接続する場合、**双方向の設定（LGW + Connection）** が必要です。

---

## 通常の S2S VPN（Azure ↔ 物理オンプレ）

物理オンプレ側のルーター/VPN アプライアンスは IKE ネゴシエーション要求を受けると自動的に応答するため、Azure 側だけに以下を設定すれば接続が成立します。

```
Azure 側のみ:
  ├── Local Network Gateway (オンプレ側の Public IP / アドレス空間)
  └── Connection (Azure VPN GW → LGW)
```

---

## Azure 同士の S2S VPN（本 HOL のケース）

Azure VPN Gateway は **受動的** で、自分宛の Connection リソースが定義されていない限り接続を確立しません。そのため **両側に明示的な設定が必要** です。

```
OnPrem 側 (vgw-onprem):                    Hub 側 (vgw-hub):
  ├── lgw-hub (Hub GW の Public IP)           ├── lgw-onprem (OnPrem GW の Public IP)
  │   └── addressPrefixes:                   │   └── addressPrefixes: 10.0.0.0/16
  │       10.10.0.0/16 (Hub)                  │
  │       10.20.0.0/16 (Spoke1)               │
  │       10.21.0.0/16 (Spoke2)               │
  │       10.22.0.0/16 (Spoke3)               │
  │       10.23.0.0/16 (Spoke4)               │
  └── cn-onprem-to-hub                       └── cn-hub-to-onprem
      └── VPN GW → lgw-hub                       └── VPN GW → lgw-onprem
      └── sharedKey: "xxx"                        └── sharedKey: "xxx"
```

---

## 必要なリソース（計 6 個）

| # | リソース名 | リソースグループ | 役割 |
|---|-----------|-----------------|------|
| 1 | `vgw-onprem` | rg-onprem | OnPrem 側 VPN Gateway |
| 2 | `lgw-hub` | rg-onprem | Hub VPN GW の Public IP とアドレス空間を定義 (Hub + Spoke1-4) |
| 3 | `cn-onprem-to-hub` | rg-onprem | OnPrem GW → Hub への S2S 接続 |
| 4 | `vgw-hub` | rg-hub | Hub 側 VPN Gateway |
| 5 | `lgw-onprem` | rg-hub | OnPrem VPN GW の Public IP とアドレス空間を定義 |
| 6 | `cn-hub-to-onprem` | rg-hub | Hub GW → OnPrem への S2S 接続 |

---

## Bicep テンプレートの構成

本 HOL では以下の 2 つのモジュールで双方向接続を実現しています。

| モジュール | 場所 | 作成リソース |
|-----------|------|------------|
| `vpn-connection.bicep` | `infra/network/modules/` | `lgw-hub` + `cn-onprem-to-hub`（OnPrem → Hub） |
| `vpn-connection-hub.bicep` | `infra/network/modules/` | `lgw-onprem` + `cn-hub-to-onprem`（Hub → OnPrem） |

両モジュールは `infra/network/main.bicep` から呼び出されます。

---

## 重要なポイント

- **共有キー（sharedKey）は両側で同一** にする必要がある
- Local Network Gateway の `addressPrefixes` には **相手側のアドレス空間** を指定する
- 片方だけだと IKE Phase 1 が成立せず **NotConnected** のままとなる
- 物理オンプレと異なり、Azure VPN Gateway は Connection リソースがないと自発的に接続しない

---

## 参考

- [Azure VPN Gateway ドキュメント](https://learn.microsoft.com/azure/vpn-gateway/)
- [VNet-to-VNet VPN Gateway 接続の構成](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-howto-vnet-vnet-resource-manager-portal)
