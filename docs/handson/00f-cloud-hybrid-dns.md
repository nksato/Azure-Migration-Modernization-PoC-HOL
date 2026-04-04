# 00f. ハイブリッド DNS の構成

VPN 接続（[00e](./00e-cloud-vpn-connect.md)）だけでは、疑似オンプレ側とクラウド側の間で名前解決ができません。  
**Azure DNS Private Resolver** を中心にした双方向の DNS 転送で、VPN 越しの名前解決を実現します。

## 目的

- 疑似オンプレ側から `privatelink.database.windows.net`（Azure SQL の Private Endpoint）を解決できるようにする
- クラウド側から `lab.local`（Active Directory ドメイン）を解決できるようにする

## 前提条件

- [00e](./00e-cloud-vpn-connect.md) が完了し、VPN の `connectionStatus` が `Connected` になっている
- Hub 側に DNS Private Resolver（`dnspr-hub`）がデプロイされている

---

## 全体像

```
疑似オンプレ (10.0.0.0/16)                    クラウド / Hub (10.10.0.0/16)
┌─────────────────────┐                      ┌──────────────────────────────┐
│  DC01 (10.0.1.4)    │                      │  DNS Private Resolver        │
│  ┌────────────────┐ │   VPN (S2S)          │  ┌────────────┐             │
│  │ DNS Server     │◄├──────────────────────├──┤ Outbound   │             │
│  │                │ │  lab.local の         │  │ Endpoint   │             │
│  │ 条件付き       │ │  クエリを転送         │  └────────────┘             │
│  │ フォワーダー   │─├──────────────────────├─►┌────────────┐             │
│  │                │ │  privatelink.*.net の  │  │ Inbound    │             │
│  └────────────────┘ │  クエリを転送         │  │ Endpoint   │             │
│                     │                      │  │ 10.10.5.4  │             │
└─────────────────────┘                      │  └─────┬──────┘             │
                                             │        │                    │
                                             │  ┌─────▼──────────────────┐ │
                                             │  │ Private DNS Zone       │ │
                                             │  │ privatelink.           │ │
                                             │  │   database.windows.net │ │
                                             │  └────────────────────────┘ │
                                             └──────────────────────────────┘
```

| 方向 | 転送元 | 転送先 | 対象ゾーン | 設定方法 | 設定タイミング |
|---|---|---|---|---|---|
| クラウド → オンプレ | DNS Private Resolver（アウトバウンド） | DC01（`10.0.1.4`） | `lab.local` | DNS Forwarding Ruleset（Bicep で自動） | 00d のデプロイ時 |
| オンプレ → クラウド | DC01（条件付きフォワーダー） | DNS Private Resolver（インバウンド `10.10.5.4`） | `privatelink.database.windows.net` | `az vm run-command`（この手順） | VPN 接続後 |

---

## 手順

### クラウド → オンプレ方向（参考）

この方向の DNS 転送は、`infra/cloud/main.bicep` のデプロイ時（[00d](./00d-cloud-deploy.md)）に以下のリソースとして**自動作成済み**です。追加の手動操作は不要です。

| リソース | 名前 | 役割 |
|---|---|---|
| DNS Forwarding Ruleset | `dnsrs-hub` | アウトバウンドエンドポイント経由で転送ルールを適用 |
| Forwarding Rule | `rule-lab-local` | `lab.local` へのクエリを DC01（`10.0.1.4:53`）に転送 |
| VNet Link | `link-vnet-hub` | ルールセットを Hub VNet に関連付け |

> テンプレートの実体は `infra/cloud/modules/network/dns-forwarding-ruleset.bicep` です。

---

### オンプレ → クラウド方向

疑似オンプレ側の DC01 に **DNS 条件付きフォワーダー**を設定します。  
`privatelink.database.windows.net` へのクエリを、Hub 側 DNS Private Resolver のインバウンドエンドポイントに転送します。

#### 1. DNS Private Resolver のインバウンド IP を取得

```powershell
$dnsInboundIp = az dns-resolver inbound-endpoint show `
  --resource-group rg-hub `
  --dns-resolver-name dnspr-hub `
  --name inbound `
  --query "ipConfigurations[0].privateIpAddress" -o tsv

$dnsInboundIp
```

> 通常 `10.10.5.4` が割り当てられます（サブネット `10.10.5.0/28` の最初の使用可能 IP）。

#### 2. DC01 に条件付きフォワーダーを追加

```powershell
az vm run-command invoke `
  --resource-group rg-onprem `
  --name vm-onprem-ad `
  --command-id RunPowerShellScript `
  --scripts "Add-DnsServerConditionalForwarderZone -Name 'privatelink.database.windows.net' -MasterServers '$dnsInboundIp' -ReplicationScope Forest"
```

#### 3. 動作確認

```powershell
az vm run-command invoke `
  --resource-group rg-onprem `
  --name vm-onprem-ad `
  --command-id RunPowerShellScript `
  --scripts "Get-DnsServerZone -Name 'privatelink.database.windows.net' | Format-List ZoneName,ZoneType,MasterServers"
```

期待する出力:

```
ZoneName      : privatelink.database.windows.net
ZoneType      : Forwarder
MasterServers : {10.10.5.4}
```

---

## 補足

- DC01 の条件付きフォワーダーは Bicep（方法 A / 方法 B いずれ）では自動設定されません。AD DS の再起動タイミングに依存するため、VPN 接続完了後にこの手順で設定します。
- `Deploy-Lab.ps1` を使う場合は、`-DnsResolverInboundIp` オプションで自動設定することもできます。詳しくは [00e](./00e-cloud-vpn-connect.md) の方法 2 を参照してください。

---

## 次のステップ

ハイブリッド DNS の設定が完了したら、移行元環境の確認に進みます。

➡ [`01-cloud-explore-onprem.md`](./01-cloud-explore-onprem.md)
