# トラブルシューティング: ドメイン参加の失敗

デプロイ後に DB01 / APP01 が `WORKGROUP` のまま `lab.local` ドメインに参加できていない場合のリカバリ手順です。

## 症状

- Azure Portal で VM Extension `DomainJoin` のステータスが `Conflict` または `Failed`
- Bastion で DB01 / APP01 に接続すると、`WORKGROUP` と表示される
- `systeminfo | findstr /B "Domain"` の結果が `lab.local` ではなく `WORKGROUP`

## 原因

`adSetupExtension` (AD DS インストール + ドメインコントローラー昇格) は、スクリプト完了後に `shutdown /r /t 60` で再起動をスケジュールします。ARM は**スクリプト完了時点**で Extension 成功と判断し、DC01 の再起動を待たずに `sqlDomainJoin` / `webDomainJoin` を開始します。この時点で AD DS がまだ起動していないため、ドメイン参加が失敗します。

```
adSetupExtension 完了 → ARM が DomainJoin を開始
         ↓                        ↓
   DC01 再起動中              AD DS 未起動 → ドメイン参加失敗
```

---

## 前提条件

- Azure CLI がインストール済み
- デプロイ時の管理者ユーザー名・パスワードを把握している

---

## 手順

### 1. 変数を設定

```powershell
$rg = "rg-onprem"
$password = "<デプロイ時の adminPassword>"
$domainName = "lab.local"
$adminUser = "labadmin"
```

> `$password` にはデプロイ時に指定した管理者パスワードをそのまま入力してください。

---

### 2. AD DS の稼働確認

DC01 で Active Directory が正常に動作していることを確認します。

```powershell
az vm run-command invoke -g $rg -n vm-onprem-ad `
  --command-id RunPowerShellScript `
  --scripts "Get-ADDomainController -Filter * | Select Name,Domain" `
  --query "value[0].message" -o tsv
```

**期待結果:**

```
Name  Domain
----  ------
DC01  lab.local
```

> 結果が返らない場合は DC01 を再起動してください:
>
> ```powershell
> az vm restart -g $rg -n vm-onprem-ad
> ```
>
> 再起動後、数分待ってから再度確認してください。

---

### 3. 失敗した Extension を削除

```powershell
# DB01
az vm extension delete -g $rg --vm-name vm-onprem-sql -n DomainJoin

# APP01
az vm extension delete -g $rg --vm-name vm-onprem-web -n DomainJoin
```

> 2 つのコマンドは別々のターミナルで並列実行できます。

---

### 4. ドメイン参加を実行

JSON ファイルを作成してから Extension を再セットします。並列実行時はファイル名の競合を避けるため、VM ごとに別のファイル名を使います。

#### DB01

```powershell
@{Name=$domainName; User="$domainName\$adminUser"; Restart="true"; Options="3"} | ConvertTo-Json | Set-Content settings-sql.json
@{Password=$password} | ConvertTo-Json | Set-Content protected-sql.json

az vm extension set -g $rg --vm-name vm-onprem-sql `
  --name JsonADDomainExtension `
  --publisher Microsoft.Compute `
  --version 1.3 `
  --settings '@settings-sql.json' `
  --protected-settings '@protected-sql.json'

Remove-Item settings-sql.json, protected-sql.json
```

#### APP01

```powershell
@{Name=$domainName; User="$domainName\$adminUser"; Restart="true"; Options="3"} | ConvertTo-Json | Set-Content settings-web.json
@{Password=$password} | ConvertTo-Json | Set-Content protected-web.json

az vm extension set -g $rg --vm-name vm-onprem-web `
  --name JsonADDomainExtension `
  --publisher Microsoft.Compute `
  --version 1.3 `
  --settings '@settings-web.json' `
  --protected-settings '@protected-web.json'

Remove-Item settings-web.json, protected-web.json
```

> 2 つのコマンドは別々のターミナルで並列実行できます。  
> 各コマンドは完了まで 3〜5 分かかります。

---

### 5. ドメイン参加の確認

```powershell
# DB01
az vm run-command invoke -g $rg -n vm-onprem-sql `
  --command-id RunPowerShellScript `
  --scripts "Get-ComputerInfo | Select CsDomain,CsPartOfDomain,CsDNSHostName | Format-List" `
  --query "value[0].message" -o tsv

# APP01
az vm run-command invoke -g $rg -n vm-onprem-web `
  --command-id RunPowerShellScript `
  --scripts "Get-ComputerInfo | Select CsDomain,CsPartOfDomain,CsDNSHostName | Format-List" `
  --query "value[0].message" -o tsv
```

**期待結果 (各 VM):**

```
CsDomain        : lab.local
CsPartOfDomain  : True
CsDNSHostName   : DB01   (または APP01)
```

---

## 根本対策: Deploy-Lab.ps1 の使用

この問題は Bicep テンプレートの `adSetupExtension` が完了してから DC01 の再起動が終わるまでの**タイミングギャップ**に起因します。

`infra/onprem/Deploy-Lab.ps1` はこの問題を想定して設計されています:

1. Bicep デプロイ時のドメイン参加失敗を**想定内エラー**として処理
2. DC01 の再起動完了を待機 (VM エージェントの Ready 状態 + AD DS 初期化待ち)
3. 失敗した `DomainJoin` Extension を自動削除
4. 最大 3 回のリトライ付きでドメイン参加を再実行

Deploy to Azure ボタンではなく、`Deploy-Lab.ps1` を使うことでドメイン参加の失敗を自動的にリカバリできます。

```powershell
cd infra/onprem
.\Deploy-Lab.ps1 -ResourceGroupName "rg-onprem" -Location "japaneast"
```

詳細は [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) を参照してください。
