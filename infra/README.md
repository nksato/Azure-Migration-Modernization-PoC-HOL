# Infrastructure Assets

この `infra/` フォルダは、ハンズオンで利用する **Bicep / ARM / パラメータ / PowerShell** を、ルート配下で参照しやすいように整理したものです。

## 構成

- `infra/cloud/`
  - クラウド側（Hub & Spoke / ガバナンス / スポーク用リソース）のテンプレート
  - `main.bicep`, `main.bicepparam`, `cloud/azuredeploy.json`, `modules/`, `scripts/`

- `infra/onprem/`
  - 疑似オンプレ側（DC01 / DB01 / APP01 / VPN Gateway）のテンプレートとセットアップ スクリプト
  - `main.bicep`, `main.json`, `main-closed.*`, `main-nat.*`, `Deploy-Lab.ps1`, `Enable-ArcOnVMs.ps1`, `scripts/`

## 参照元

- `tmp/cloud/infra/**`
- `tmp/onprem/infra/**`
- `tmp/onprem/scripts/**`

> `tmp/` 配下の資料をベースに、ルートから扱いやすいように整理してコピーした配置です。
