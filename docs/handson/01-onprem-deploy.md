# 01. 疑似オンプレ環境のデプロイ

この手順では、Azure 上に**移行元として使う疑似オンプレ環境**を構築します。

## 事前準備

- Azure サブスクリプション
- リソースグループ作成権限
- VM 管理者パスワード
- VPN 接続を使う場合は事前共有キー

## 使用するテンプレート

| テンプレート | 用途 |
|---|---|
| `tmp/onprem/infra/main.bicep` | 標準ラボ構成 |

---

## 方法 1: PowerShell スクリプトでデプロイ（推奨）

`tmp/onprem/Deploy-Lab.ps1` を使うと、テンプレートの切り替えや再実行がしやすくなります。

```powershell
Set-Location .\tmp\onprem

# 標準ラボ構成
.\Deploy-Lab.ps1 `
  -ResourceGroupName "rg-onpre" `
  -Location "japaneast" `
  -TemplateFile "infra/main.bicep"
```

---

## 方法 2: Bicep を直接デプロイ

```powershell
az group create --name rg-onpre --location japaneast

az deployment group create `
  --resource-group rg-onpre `
  --template-file tmp/onprem/infra/main.bicep `
  --parameters adminPassword='<管理者パスワード>' vpnSharedKey='<共有キー>'
```

---

## デプロイ後に確認すること

- `OnPrem-AD` / `OnPrem-SQL` / `OnPrem-Web` が作成されている
- `Azure Bastion` が作成されている
- `VPN Gateway` が作成されている
- VM 3 台にパブリック IP が付いていない

---

## 次のステップ

デプロイが完了したら、次に Parts Unlimited をセットアップします。

➡ [`02-onprem-parts-unlimited.md`](./02-onprem-parts-unlimited.md)
