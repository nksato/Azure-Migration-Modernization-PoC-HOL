# 00a. 疑似オンプレ環境のデプロイ

> **Note**  
> [`00-initial-setup.md`](./00-initial-setup.md) の **Deploy to Azure** でセットアップ済みの場合、このページの手順は不要です。

Azure 上に**移行元として使う疑似オンプレ環境**を構築します。

## 目的

- `DC01` / `DB01` / `APP01` を含む疑似オンプレ環境を Azure 上に作成する
- Azure Bastion 経由の管理アクセスを確保する
- VPN Gateway を作成し、後続のクラウド側接続に備える

## 前提条件

- Azure サブスクリプション
- リソースグループ作成権限
- VM 管理者パスワード
- VPN 接続を使う場合は事前共有キー

> `vpnSharedKey` には 32 文字以上のランダムな文字列を指定してください。以下のコマンドで生成できます。
>
> ```powershell
> -join ((65..90)+(97..122)+(48..57)+(33,35,36,37,38,42,43,45,61,64)|Get-Random -Count 40|%{[char]$_})
> ```
>
> 生成例: `qb06eQr=a7I@LKY#&!ljw+d2GZzSTnkyXt-p1gc%`（この値はそのまま使わず、必ず自分で生成してください）

## 使用するテンプレート

| テンプレート | 用途 |
|---|---|
| `infra/onprem/main.bicep` | 標準ラボ構成 |

---

## Deploy to Azure ボタン

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnksato%2FAzure-Migration-Modernization-PoC-HOL%2Fmain%2Finfra%2Fonprem%2Fdeploy.json)

> Portal でリージョンとパラメータを入力してデプロイします。リソースグループ `rg-onprem` は自動作成されます。

---

## 方法 1: PowerShell スクリプトでデプロイ（推奨）

`infra/onprem/Deploy-Lab.ps1` を使うと、管理者パスワードや VPN 共有キーを対話的に入力しながら、再実行しやすくなります。

```powershell
Set-Location .\infra\onprem

# 標準ラボ構成
.\Deploy-Lab.ps1 `
  -ResourceGroupName "rg-onprem" `
  -Location "japaneast"
```

---

## 方法 2: Bicep を直接デプロイ

```powershell
az group create --name rg-onprem --location japaneast

az deployment group create `
  --resource-group rg-onprem `
  --template-file infra/onprem/main.bicep `
  --parameters adminPassword='<管理者パスワード>' vpnSharedKey='<共有キー>'
```

---

## 完了確認

- `vm-onprem-ad` / `vm-onprem-sql` / `vm-onprem-web` が作成されている
- `Azure Bastion` が作成されている
- `VPN Gateway` が作成されている
- VM 3 台にパブリック IP が付いていない

---

## 次のステップ

デプロイが完了したら、次に Parts Unlimited をセットアップします。

➡ [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md)
