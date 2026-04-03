# 00e. クラウド VPN 接続の構成

この手順では、`00a` で作成した**疑似オンプレ側 Azure VPN Gateway** と、`00d` で作成した **Hub 側 Azure VPN Gateway** を接続し、ハンズオンで利用する **S2S VPN** を成立させます。

## 目的

- Hub 側 VPN Gateway の公開 IP を取得する
- 疑似オンプレ側に `Local Network Gateway` を作成する
- `OnPrem-to-Azure-S2S` 接続を構成する

---

## 前提

- [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) が完了している
- [`00d-cloud-deploy.md`](./00d-cloud-deploy.md) が完了している
- `OnPrem-VpnGw` と `vgw-hub` の作成が完了している
- Step 1 で指定した `vpnSharedKey` を控えている

> **VPN 共有キーの注意**: `vpnSharedKey` には **32 文字以上** の十分にランダムな文字列を使い、クラウド側 / 疑似オンプレ側で**完全に同じ値**を指定してください。サンプル値や推測しやすい文字列は避けてください。

> VPN Gateway のデプロイ完了には時間がかかるため、作成直後は数十分待ってから次に進んでください。

---

## 事前に確認する値

| 項目 | 値の例 | 用途 |
|---|---|---|
| Hub 側リソースグループ | `rg-hub` | クラウド側 VPN Gateway の参照先 |
| 疑似オンプレ側リソースグループ | `rg-onprem` | 接続設定のデプロイ先 |
| Hub 側公開 IP | `pip-vgw-hub` | `remoteGatewayIp` に指定 |
| Azure 側アドレス空間 | `10.10.0.0/16` | `remoteAddressPrefix` に指定 |
| 事前共有キー | `<共有キー>` | `vpnSharedKey` に指定（Step 1 と同じ値） |

---

## 方法 1: Bicep で接続設定を追加

### 1) Hub 側 VPN Gateway の公開 IP を取得

```powershell
$hubGatewayIp = az network public-ip show `
  --resource-group rg-hub `
  --name pip-vgw-hub `
  --query ipAddress -o tsv

$hubGatewayIp
```

### 2) 疑似オンプレ側から接続設定を追加

```powershell
az deployment group create `
  --name hol-onprem-vpn-connection `
  --resource-group rg-onprem `
  --template-file infra/onprem/main.bicep `
  --parameters adminPassword='<管理者パスワード>' `
               vpnSharedKey='<共有キー>' `
               remoteGatewayIp=$hubGatewayIp `
               remoteAddressPrefix='10.10.0.0/16'
```

この再デプロイでは既存 VM を作り直すのではなく、主に以下を追加・更新します。

- `Azure-LocalGw`
- `OnPrem-to-Azure-S2S`

---

## 方法 2: `Deploy-Lab.ps1` を再実行する場合

```powershell
Set-Location .\infra\onprem

.\Deploy-Lab.ps1 `
  -ResourceGroupName "rg-onprem" `
  -Location "japaneast" `
  -RemoteGatewayIp $hubGatewayIp `
  -RemoteAddressPrefix "10.10.0.0/16"
```

> `vpnSharedKey` には、Step 1 で指定したものと**同じ値**を入力してください。

---

## 完了後に確認すること

```powershell
az network vpn-connection show `
  --resource-group rg-onprem `
  --name OnPrem-to-Azure-S2S `
  --query "{name:name, provisioningState:provisioningState, connectionStatus:connectionStatus}" `
  -o table
```

期待する状態:

- `provisioningState` が `Succeeded`
- `connectionStatus` が `Connected`（反映直後は数分後に `Connected` になる場合があります）

あわせて以下も確認してください。

- `Azure-LocalGw` が作成されている
- `OnPrem-VpnGw` / `vgw-hub` が存在している
- 疑似オンプレ側から Hub 側アドレス空間への接続設定ができている

---

## 補足

- 現在のテンプレート構成では、接続先情報と共有キーを使った **S2S 接続の作成は疑似オンプレ側の再デプロイで完了**します。
- そのため、`00d` 実施後にクラウド側で追加の手動設定を行う必要はありません。
- 接続状態が `Connected` にならない場合は、`vpnSharedKey` と `remoteGatewayIp` の値を再確認してください。

---

## 次のステップ

VPN 接続が確立したら、ハイブリッド DNS の構成に進みます。

➡ [`00f-cloud-hybrid-dns.md`](./00f-cloud-hybrid-dns.md)
