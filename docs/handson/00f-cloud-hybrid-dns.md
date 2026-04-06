# 00f. ハイブリッド DNS の構成

> **Note**  
> このページは [`00-initial-setup.md`](./00-initial-setup.md) の **方法 A「デプロイ後に必要な手動設定」** および **方法 B — Step 5** の詳細手順です。  
> 方法 A で Deploy to Azure を使った場合も、DNS 転送設定は自動化されないため、このページの手順を実行してください。

VPN 接続（[00e](./00e-cloud-vpn-connect.md)）だけでは、疑似オンプレ側とクラウド側の間で名前解決ができません。  
**Azure DNS Private Resolver** を中心にした双方向の DNS 転送で、VPN 越しの名前解決を実現します。

## 目的

- クラウド側から `lab.local`（Active Directory ドメイン）を解決できるようにする
- 疑似オンプレ側から `privatelink.database.windows.net`（Azure SQL の Private Endpoint）を解決できるようにする

## 前提条件

- [00e](./00e-cloud-vpn-connect.md) が完了し、VPN の `connectionStatus` が `Connected` になっている
- Hub 側に DNS Private Resolver（`dnspr-hub`）がデプロイされている
- `az login` 済みであること

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

| 方向 | 転送元 | 転送先 | 対象ゾーン | 設定方法 |
|---|---|---|---|---|
| クラウド → オンプレ | DNS Private Resolver（アウトバウンド） | DC01（`10.0.1.4`） | `lab.local` | DNS Forwarding Ruleset（スクリプト） |
| オンプレ → クラウド | DC01（条件付きフォワーダー） | DNS Private Resolver（インバウンド `10.10.5.4`） | `privatelink.database.windows.net` | `az vm run-command`（スクリプト） |

---

## 手順

### 方法 1: スクリプトで一括実行（推奨）

`Setup-HybridDns.ps1` を実行すると、上記の双方向 DNS 転送をまとめて設定します。

```powershell
.\infra\network\Setup-HybridDns.ps1
```

スクリプトは以下の 2 ステップを自動実行します。

| ステップ | 方向 | 内容 |
|---|---|---|
| [1/2] | クラウド → オンプレ | DNS Forwarding Ruleset（`dnsrs-hub`）を作成し、`lab.local` → DC01（`10.0.1.4`）の転送ルールを追加 |
| [2/2] | オンプレ → クラウド | DC01 に `privatelink.database.windows.net` → DNS Resolver Inbound IP の条件付きフォワーダーを追加 |

> パラメータのカスタマイズ:
> ```powershell
> .\infra\network\Setup-HybridDns.ps1 `
>   -OnpremResourceGroup rg-onprem `
>   -HubResourceGroup rg-hub
> ```

---

### 方法 2: 手動で個別に実行

#### [1/2] クラウド → オンプレ方向

DNS Forwarding Ruleset を作成し、`lab.local` のクエリを DC01 に転送します。

```powershell
# Outbound Endpoint ID を取得
$outboundEpId = az dns-resolver outbound-endpoint show `
  --resource-group rg-hub `
  --dns-resolver-name dnspr-hub `
  --name outbound `
  --query "id" -o tsv

# Hub VNet ID を取得
$hubVnetId = az network vnet show `
  --resource-group rg-hub `
  --name vnet-hub `
  --query "id" -o tsv

# DNS Forwarding Ruleset を作成
az dns-resolver forwarding-ruleset create `
  --resource-group rg-hub `
  --name dnsrs-hub `
  --location japaneast `
  --outbound-endpoints "[{id:$outboundEpId}]"

# 転送ルールを追加
az dns-resolver forwarding-rule create `
  --resource-group rg-hub `
  --ruleset-name dnsrs-hub `
  --name rule-lab-local `
  --domain-name "lab.local." `
  --forwarding-rule-state Enabled `
  --target-dns-servers "[{ip-address:10.0.1.4,port:53}]"

# ルールセットを Hub VNet にリンク
az dns-resolver forwarding-ruleset vnet-link create `
  --resource-group rg-hub `
  --ruleset-name dnsrs-hub `
  --name link-vnet-hub `
  --id $hubVnetId
```

#### [2/2] オンプレ → クラウド方向

DC01 に DNS 条件付きフォワーダーを設定します。

```powershell
# DNS Private Resolver のインバウンド IP を取得
$dnsInboundIp = az dns-resolver inbound-endpoint show `
  --resource-group rg-hub `
  --dns-resolver-name dnspr-hub `
  --name inbound `
  --query "ipConfigurations[0].privateIpAddress" -o tsv

$dnsInboundIp

# DC01 に条件付きフォワーダーを追加
az vm run-command invoke `
  --resource-group rg-onprem `
  --name vm-onprem-ad `
  --command-id RunPowerShellScript `
  --scripts "Add-DnsServerConditionalForwarderZone -Name 'privatelink.database.windows.net' -MasterServers '$dnsInboundIp' -ReplicationScope Forest"
```

> 通常 `10.10.5.4` が割り当てられます（サブネット `10.10.5.0/28` の最初の使用可能 IP）。
>
> **既知の問題**: Azure CLI 2.78.0 では `az vm run-command invoke --scripts` にスクリプトが正しく渡されないバグがあります。上記コマンドが動作しない場合は、`az vm run-command create` で代替してください。
>
> ```powershell
> az vm run-command create -g rg-onprem --vm-name vm-onprem-ad --name SetupDns `
>   --script "Add-DnsServerConditionalForwarderZone -Name 'privatelink.database.windows.net' -MasterServers '$dnsInboundIp' -ReplicationScope Forest"
> az vm run-command show -g rg-onprem --vm-name vm-onprem-ad --name SetupDns --instance-view --query "instanceView" -o json
> az vm run-command delete -g rg-onprem --vm-name vm-onprem-ad --name SetupDns --yes
> ```

---

## 動作確認

```powershell
# クラウド → オンプレ: DNS Forwarding Ruleset の確認
az dns-resolver forwarding-rule list `
  --resource-group rg-hub `
  --ruleset-name dnsrs-hub `
  --query "[].{Name:name, Domain:domainName, State:forwardingRuleState, Target:targetDnsServers[0].ipAddress}" `
  -o table

# オンプレ → クラウド: 条件付きフォワーダーの確認
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

- DNS Forwarding Ruleset と DC01 の条件付きフォワーダーは Bicep では自動設定されません。VPN 接続確立後にこの手順で設定します。
- `Setup-HybridDns.ps1` は冪等に設計されており、既存の条件付きフォワーダーがある場合は MasterServers を更新します。

> [!TIP]
> Azure CLI と `az vm run-command` で DNS 設定状態・双方向の名前解決を一括検証できるスクリプトも用意しています。
> VM 内部には入らず外部から諸元（Resolver 状態・転送ルール・条件付きフォワーダー・クロスネットワーク名前解決など）を確認する簡易チェックのため、ポータル画面での目視確認は含みません。
>
> ```powershell
> .\infra\network\scripts\Verify-HybridDns.ps1
> ```

---

## 次のステップ

ハイブリッド DNS の設定が完了したら、移行元環境の確認に進みます。

➡ [`01-cloud-explore-onprem.md`](./01-cloud-explore-onprem.md)
