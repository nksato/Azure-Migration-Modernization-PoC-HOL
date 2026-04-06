# 00b. Parts Unlimited セットアップ

疑似オンプレ環境の `DB01` と `APP01` に **Parts Unlimited** をセットアップします。

## 目的

- `DB01` に SQL Server の認証・ネットワーク設定を行い、アプリ用 DB を準備する
- `APP01` に Parts Unlimited をビルド・デプロイし、Web アプリを稼働させる

## 前提条件

- `00a-onprem-deploy.md` の手順で環境作成済み
- `Azure Bastion` 経由で `DB01` / `APP01` に接続できる
- `DB01` / `APP01` でセットアップ スクリプトを実行できる

---

## 1. DB01 で SQL Server を準備

Bastion で `vm-onprem-sql (DB01)` に接続し、管理者 PowerShell を開きます。

```powershell
# <github-owner>/<repo-name> は自身の fork / mirror に置き換えてください
$repo = 'https://raw.githubusercontent.com/<github-owner>/<repo-name>/main/infra/onprem/scripts'
New-Item -Path C:\scripts -ItemType Directory -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "$repo/Setup-SqlServer.ps1" -OutFile 'C:\scripts\Setup-SqlServer.ps1' -UseBasicParsing

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
C:\scripts\Setup-SqlServer.ps1 -SqlPassword '<任意の強いパスワード>'
```

### 実行内容

- SQL 認証の有効化
- TCP/IP の有効化
- TCP 1433 のファイアウォール許可
- `puadmin` ログイン作成

---

## 2. APP01 に Web アプリを配置

Bastion で `vm-onprem-web (APP01)` に接続し、管理者 PowerShell を開きます。

```powershell
# <github-owner>/<repo-name> は自身の fork / mirror に置き換えてください
$repo = 'https://raw.githubusercontent.com/<github-owner>/<repo-name>/main/infra/onprem/scripts'
New-Item -Path C:\scripts -ItemType Directory -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "$repo/Setup-PartsUnlimited.ps1" -OutFile 'C:\scripts\Setup-PartsUnlimited.ps1' -UseBasicParsing

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
C:\scripts\Setup-PartsUnlimited.ps1 -SqlPassword '<DB01 と同じパスワード>'
```

### 実行内容

- Build Tools / NuGet の準備
- アプリ ソース取得
- ビルド
- IIS サイト作成
- `DB01` 向け接続文字列設定
- 初回 HTTP リクエストによる DB 初期化（EF Code First マイグレーション）

---

## 備考: リモート PC から `az vm run-command` で実行する場合

Bastion で VM にログインせず、手元の PC から Azure CLI を使って `DB01` / `APP01` のセットアップを実行することもできます。

> `--name` に指定するのはホスト名ではなく Azure VM リソース名です。ここでは `vm-onprem-sql` と `vm-onprem-web` を使います。必要に応じて `az vm list --resource-group rg-onprem --query "[].name" -o tsv` で確認してください。

```powershell
# DB01 (vm-onprem-sql) — SQL Server セットアップ
az vm run-command invoke `
  --resource-group rg-onprem `
  --name vm-onprem-sql `
  --command-id RunPowerShellScript `
  --scripts @infra/onprem/scripts/Setup-SqlServer-en.ps1 `
  --parameters "SqlPassword=<任意の強いパスワード>" `
  --query "value[].message" -o tsv

# APP01 (vm-onprem-web) — Parts Unlimited デプロイ
az vm run-command invoke `
  --resource-group rg-onprem `
  --name vm-onprem-web `
  --command-id RunPowerShellScript `
  --scripts @infra/onprem/scripts/Setup-PartsUnlimited-en.ps1 `
  --parameters "SqlPassword=<DB01 と同じパスワード>" `
  --query "value[].message" -o tsv
```

> 日本語を含むスクリプトは文字コードの影響で実行エラーになることがあるため、VM Run Command では `*-en.ps1` を利用しています。

> `Setup-PartsUnlimited-en.ps1` は完了まで 15〜20 分程度かかる場合があります。
>
> **既知の問題**: Azure CLI 2.78.0 では `az vm run-command invoke --scripts` にスクリプトが正しく渡されないバグがあります。上記コマンドが動作しない場合は、`az vm run-command create` を使用してください。
>
> ```powershell
> # DB01 — az vm run-command create による代替実行
> az vm run-command create -g rg-onprem --vm-name vm-onprem-sql --name SetupSql `
>   --script (Get-Content infra/onprem/scripts/Setup-SqlServer-en.ps1 -Raw) `
>   --parameters SqlPassword='<パスワード>'
> az vm run-command show -g rg-onprem --vm-name vm-onprem-sql --name SetupSql --instance-view --query "instanceView" -o json
>
> # APP01 — az vm run-command create による代替実行
> az vm run-command create -g rg-onprem --vm-name vm-onprem-web --name SetupPU `
>   --script (Get-Content infra/onprem/scripts/Setup-PartsUnlimited-en.ps1 -Raw) `
>   --parameters SqlPassword='<パスワード>'
> az vm run-command show -g rg-onprem --vm-name vm-onprem-web --name SetupPU --instance-view --query "instanceView" -o json
> ```

---

## 3. 動作確認

APP01 の RDP セッション内でブラウザを開き、以下へアクセスします。

```text
http://localhost
```

### 期待結果

- `Parts Unlimited` のホーム画面が表示される
- 商品一覧やカテゴリが見える

> セットアップスクリプトの最終ステップで初回 HTTP リクエストを実行し DB を自動生成します。スクリプト実行時に DB 初期化が失敗した場合は、このブラウザアクセスが実質的な初回アクセスとなり、ページ表示まで数十秒かかることがあります。

### 管理者ログイン（サンプル既定値）

| 項目 | 値 |
|---|---|
| Email | `Administrator@test.com` |
| Password | `YouShouldChangeThisPassword1!` |

---

## トラブルシューティング

- `DB01` の SQL Server サービスが起動しているか
- `APP01` から `10.0.1.5:1433` に到達できるか
- IIS アプリケーションプールが起動しているか

詳しい確認は次の手順を参照してください。

➡ [`00c-onprem-verification.md`](./00c-onprem-verification.md)
