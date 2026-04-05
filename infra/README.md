# Infrastructure Assets

この `infra/` フォルダは、ハンズオンで利用する **Bicep / ARM / パラメータ / PowerShell** を、ルート配下で参照しやすいように整理したものです。

## 構成

- `infra/main.bicep`
  - 初期環境を一括セットアップする正式エントリポイント
  - `infra/cloud/main.bicep` と `infra/onprem/resources.bicep` を呼び出す

- `infra/cloud/`
  - クラウド側（Hub & Spoke / ガバナンス / スポーク用リソース）のテンプレート
  - `main.bicep`, `main.bicepparam`, `azuredeploy.json`, `modules/`, `scripts/`

- `infra/onprem/`
  - 疑似オンプレ側（DC01 / DB01 / APP01 / VPN Gateway）のテンプレートとセットアップ スクリプト
  - `main.bicep`, `main.json`, `Deploy-Lab.ps1`, `Enable-ArcOnVMs.ps1`, `scripts/`

- `infra/tmp/`
  - 旧構成由来の疑似オンプレ / アプリ関連ファイルを一時退避した領域
  - `modules/`, `scripts/`

## 補足

この `infra/` フォルダには、ハンズオンで直接利用するテンプレートと補助スクリプトを配置しています。
