# 00a. 疑似オンプレ環境のデプロイ

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

> `vpnSharedKey` には 32 文字以上のランダムな文字列を指定してください。英大文字・小文字・数字・記号を組み合わせ、サンプル値は使わないでください。

## 使用するテンプレート

| テンプレート | 用途 |
|---|---|
| `infra/onprem/main.bicep` | 標準ラボ構成 |

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

- `OnPrem-AD` / `OnPrem-SQL` / `OnPrem-Web` が作成されている
- `Azure Bastion` が作成されている
- `VPN Gateway` が作成されている
- VM 3 台にパブリック IP が付いていない

---

## 次のステップ

デプロイが完了したら、次に Parts Unlimited をセットアップします。

➡ [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md)
