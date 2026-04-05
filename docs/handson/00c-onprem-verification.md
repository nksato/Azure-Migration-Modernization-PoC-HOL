# 00c. 疑似オンプレ環境の動作確認

デプロイ済みの疑似オンプレ環境が閉域かつ正常に動作していることを確認します。

## 目的

- VM にパブリック IP が付いていないことを確認する
- AD / SQL Server / IIS が正常に稼働していることを確認する
- Parts Unlimited が表示できることを確認する

## 前提条件

- [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) のデプロイが完了している
- [`00b-onprem-parts-unlimited.md`](./00b-onprem-parts-unlimited.md) のセットアップが完了している

---

## 手順

### 1. パブリック IP が付いていないことを確認

```powershell
az network nic show --resource-group rg-onprem --name nic-vm-onprem-ad --query "ipConfigurations[].publicIPAddress" -o tsv
az network nic show --resource-group rg-onprem --name nic-vm-onprem-sql --query "ipConfigurations[].publicIPAddress" -o tsv
az network nic show --resource-group rg-onprem --name nic-vm-onprem-web --query "ipConfigurations[].publicIPAddress" -o tsv
```

**期待結果:** いずれも出力なし

---

### 2. Azure Bastion で接続できることを確認

Azure Portal から以下 3 台に接続し、ログインできることを確認します。

- `vm-onprem-ad`
- `vm-onprem-sql`
- `vm-onprem-web`

---

### 3. 各サーバの役割確認

### DC01

```powershell
(Get-ADDomain).DNSRoot
Get-DnsServerZone | Select-Object ZoneName, ZoneType
```

**期待結果:** `lab.local` が確認できる

### DB01

```powershell
Get-Service MSSQLSERVER | Select-Object Name, Status
sqlcmd -S localhost -Q "SELECT @@SERVERNAME AS ServerName"
```

**期待結果:** SQL Server が `Running`

### APP01

```powershell
Get-WindowsFeature Web-Server | Select-Object Name, InstallState
Invoke-WebRequest -Uri http://localhost -UseBasicParsing | Select-Object StatusCode
```

**期待結果:** IIS がインストール済み、`StatusCode` が `200`

---

### 4. 内部疎通確認

### APP01 → DB01

```powershell
Test-NetConnection -ComputerName 10.0.1.5 -Port 1433
```

### APP01 → DC01

```powershell
Test-NetConnection -ComputerName 10.0.1.4 -Port 3389
Resolve-DnsName DC01.lab.local
```

**期待結果:** `TcpTestSucceeded : True`

---

### 5. Web アプリ表示確認

APP01 上のブラウザで以下を開きます。

```text
http://localhost
```

**期待結果:**

- `Parts Unlimited` のトップページが表示される
- カテゴリや商品が表示される
- エラーなく画面遷移できる

---

## 完了確認

以下が満たされていれば、疑似オンプレ環境の準備は完了です。

- VM にパブリック IP が付いていない
- Bastion で 3 台すべてに接続できる
- AD / SQL / IIS が正常に動作している
- Parts Unlimited が表示される

> この状態になれば、以降の移行 HOL の移行元環境として利用できます。

> [!TIP]
> Bastion に接続せず、ローカル PC から `az vm run-command` で一括検証できるスクリプトも用意しています。
> VM 内部に入らず外部から諸元（サービス状態・ドメイン参加・ポート疎通など）を確認する簡易チェックのため、ブラウザでの画面表示確認やアプリの操作確認は含みません。
>
> ```powershell
> .\infra\onprem\scripts\Verify-OnpremSetup.ps1
> ```
>
> Parts Unlimited のセットアップ前に実行する場合は `-SkipPartsUnlimited` を付けてください。
