# 01. Parts Unlimited セットアップ

この手順では、疑似オンプレ環境の `DB01` と `APP01` に **Parts Unlimited** をセットアップします。

## 前提条件

- `00-deploy.md` の手順で環境作成済み
- `Azure Bastion` 経由で `DB01` / `APP01` に接続できる
- 外部からスクリプトを取得する場合は `main-nat.bicep` など送信可能な構成である

---

## 1. DB01 で SQL Server を準備

Bastion で `OnPrem-SQL (DB01)` に接続し、管理者 PowerShell を開きます。

```powershell
$repo = 'https://raw.githubusercontent.com/nksato/Azure-Migration-Modernization-PoC-HOL/main/tmp/onprem/scripts'
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

Bastion で `OnPrem-Web (APP01)` に接続し、管理者 PowerShell を開きます。

```powershell
$repo = 'https://raw.githubusercontent.com/nksato/Azure-Migration-Modernization-PoC-HOL/main/tmp/onprem/scripts'
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

---

## 3. 動作確認

APP01 の RDP セッション内でブラウザを開き、以下へアクセスします。

```text
http://localhost
```

### 期待結果

- `Parts Unlimited` のホーム画面が表示される
- 商品一覧やカテゴリが見える
- 初回アクセス時に DB が自動作成される場合がある

### 管理者ログイン（サンプル既定値）

| 項目 | 値 |
|---|---|
| Email | `Administrator@test.com` |
| Password | `YouShouldChangeThisPassword1!` |

---

## トラブル時の確認ポイント

- `DB01` の SQL Server サービスが起動しているか
- `APP01` から `10.0.1.5:1433` に到達できるか
- IIS アプリケーションプールが起動しているか

詳しい確認は次の手順を参照してください。

➡ [`02-verification.md`](./02-verification.md)
