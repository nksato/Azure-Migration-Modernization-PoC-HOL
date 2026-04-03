# Infrastructure Assets

この `infra/` フォルダは、ハンズオンで利用する **Bicep / ARM / パラメータ / PowerShell** を、ルート配下で参照しやすいように整理したものです。

## 構成

- `infra/main.bicep`
  - 初期環境を一括セットアップする正式エントリポイント
  - `infra/cloud/cloud/main.bicep` と `infra/onprem/main.bicep` を呼び出す

- `infra/cloud/`
  - クラウド側（Hub & Spoke / ガバナンス / スポーク用リソース）のテンプレート
  - `main.bicep`（互換性維持用ラッパー）, `main.bicepparam`, `cloud/azuredeploy.json`, `modules/`, `scripts/`

- `infra/onprem/`
  - 疑似オンプレ側（DC01 / DB01 / APP01 / VPN Gateway）のテンプレートとセットアップ スクリプト
  - `main.bicep`, `main.json`, `Deploy-Lab.ps1`, `Enable-ArcOnVMs.ps1`, `scripts/`

## 補足

この `infra/` フォルダには、ハンズオンで直接利用するテンプレートと補助スクリプトを配置しています。
