# 00e. VPN Gateway 配置・接続

> **Note**  
> [`00-initial-setup.md`](./00-initial-setup.md) の **Deploy to Azure** でセットアップ済みの場合、VPN 接続設定も含まれているため、このページの手順は不要です。

疑似オンプレ側と Hub 側の両方に VPN Gateway をデプロイし、**S2S VPN** を成立させます。  
あわせて Hub-Spoke 間の VNet Peering を Gateway Transit 有効で更新します。

## 目的

- 疑似オンプレ側 VNet に GatewaySubnet と VPN Gateway を追加する
- Hub 側に VPN Gateway をデプロイする
- `Local Network Gateway` と S2S 接続を構成する
- Hub-Spoke 間の VNet Peering を Gateway Transit 有効に更新する

---

## 前提条件

- [`00a-onprem-deploy.md`](./00a-onprem-deploy.md)（Step 1）が完了している
- [`00d-cloud-deploy.md`](./00d-cloud-deploy.md)（Step 3）が完了している
- `vpnSharedKey` に使用する共有キーを準備している

> VPN Gateway のデプロイには 30〜45 分程度かかります。

### 事前に準備する値

| 項目 | 値の例 | 説明 |
|---|---|---|
| VPN 共有キー | `<共有キー>` | S2S 接続に使用する事前共有キー（32 文字以上推奨） |

> `vpnSharedKey` には 32 文字以上のランダムな文字列を指定してください。以下のコマンドで生成できます。
>
> ```powershell
> $vpnKey = -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 40 | %{[char]$_})
> Write-Host "vpnSharedKey = $vpnKey"
> ```

---

## 手順

### Deploy to Azure ボタン

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fnetwork%2Fmain.json)

### Azure CLI / Bicep で実行する場合

`infra/network/main.bicep` は Subscription スコープのテンプレートで、以下を一括処理します。

1. 疑似オンプレ VNet に GatewaySubnet を追加し VPN Gateway をデプロイ
2. Hub VNet に VPN Gateway をデプロイ
3. 両方の Public IP を取得し、Local Network Gateway + S2S 接続を作成
4. Hub-Spoke 間の VNet Peering を Gateway Transit 有効で再デプロイ

```powershell
# 共有キーを生成して変数に格納（英数字 40 文字）
$vpnKey = -join ((65..90)+(97..122)+(48..57) | Get-Random -Count 40 | %{[char]$_})
Write-Host "vpnSharedKey = $vpnKey"

az deployment sub create `
  --name hol-vpn-setup `
  --location japaneast `
  --template-file infra/network/main.bicep `
  --parameters vpnSharedKey="$vpnKey"
```

> `&`, `!`, `%` などの特殊文字を含む共有キーは、`az` CLI に渡す際にシェルに解釈されてエラーになることがあります。上記のように英数字のみで生成し、変数経由で渡すのが安全です。

> **Tip**: デプロイ後に共有キーを確認するには、以下のコマンドを使用してください。
>
> ```powershell
> az network vpn-connection shared-key show `
>   --resource-group rg-onprem --name cn-onprem-to-hub -o tsv
> ```

---

## 完了確認

```powershell
# VPN 接続状態の確認
az network vpn-connection show `
  --resource-group rg-onprem `
  --name cn-onprem-to-hub `
  --query "{name:name, provisioningState:provisioningState, connectionStatus:connectionStatus}" `
  -o table
```

期待する状態:

- `provisioningState` が `Succeeded`
- `connectionStatus` が `Connected`（反映直後は数分後に `Connected` になる場合があります）

あわせて以下も確認してください。

- `vgw-onprem`（疑似オンプレ側）と `vgw-hub`（Hub 側）の VPN Gateway が作成されている
- `lgw-hub`（Local Network Gateway）が作成されている
- Hub-Spoke 間の VNet Peering で `AllowGatewayTransit` / `UseRemoteGateways` が有効になっている

---

## 補足

- このテンプレートは疑似オンプレ側とクラウド側の両方に VPN Gateway を作成するため、完了まで時間がかかります。
- 接続状態が `Connected` にならない場合は、`vpnSharedKey` の値を確認してください。
- テンプレートの実体:
  - `infra/network/main.bicep` — VPN 配置のエントリポイント
  - `infra/network/modules/onprem-vpn-gateway.bicep` — 疑似オンプレ側 GatewaySubnet + VPN GW
  - `infra/network/modules/vpn-connection.bicep` — LGW + S2S 接続
  - `infra/network/modules/update-hub-peering.bicep` — Peering の Gateway Transit 有効化

> [!TIP]
> Azure CLI から VPN Gateway・s2S 接続・ピアリングの状態を一括検証できるスクリプトも用意しています。
> VM 内部には入らず Azure API だけで諸元（プロビジョニング状態・SKU・接続ステータス・Gateway Transit 設定など）を確認する簡易チェックのため、ポータル画面での目視確認は含みません。
>
> ```powershell
> .\infra\network\scripts\Verify-VpnConnection.ps1
> ```

---

## 次のステップ

VPN 接続が確立したら、ハイブリッド DNS の構成に進みます。

➡ [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md)
