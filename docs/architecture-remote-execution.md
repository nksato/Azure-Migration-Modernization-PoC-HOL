# リモート実行方式 — Azure VM への PowerShell リモート実行パターン

## 概要

本 HOL では、Azure VM やオンプレ VM に対して **RDP で直接ログインせず** に PowerShell スクリプトを実行する場面が多くあります。本ドキュメントでは、VM へのリモート実行・リモート接続の各方式を比較し、本 HOL での使い分けを整理します。

---

## 方式比較

| 方式 | ネットワーク要件 | 対話型 | 認証 | 主な用途 |
|------|----------------|--------|------|---------|
| `az vm run-command invoke` | なし（Azure API 経由） | ❌ | Azure RBAC | Azure VM へのスクリプト実行 |
| `az connectedmachine run-command` | なし（Azure API 経由） | ❌ | Azure RBAC | Arc 対応 VM へのスクリプト実行 |
| Azure Bastion（ブラウザ RDP） | Bastion のみ | ✅ | VM ローカル認証 | 対話的な操作・GUI 作業 |
| Azure Bastion（ネイティブクライアント） | Bastion Standard 以上 | ✅ | VM ローカル認証 | ローカル端末からの SSH/RDP |
| PowerShell Remoting（WinRM） | VPN + WinRM 設定 | ✅ | Windows 認証 | 頻繁な対話操作 |

---

## 方式 1: `az vm run-command invoke`（Azure VM 向け）

Azure API 経由で VM 内のスクリプトを実行します。ネットワーク設定は不要で、VM Agent が動作していれば利用可能です。

```
ローカル PC → Azure API (management.azure.com) → VM Agent → PowerShell 実行
```

### 使用例

```powershell
# 単一コマンドの実行
az vm run-command invoke -g rg-spoke1 -n vm-spoke1-test `
  --command-id RunPowerShellScript `
  --scripts "hostname; Get-NetIPAddress -AddressFamily IPv4 | Select InterfaceAlias, IPAddress"

# スクリプトファイルの実行
az vm run-command invoke -g rg-spoke1 -n vm-spoke1-test `
  --command-id RunPowerShellScript `
  --scripts @my-script.ps1

# パラメータ付き実行
az vm run-command invoke -g rg-spoke1 -n vm-spoke1-test `
  --command-id RunPowerShellScript `
  --scripts "param($Name) Write-Output \"Hello, $Name\"" `
  --parameters "Name=Azure"
```

### 制約

| 項目 | 制限 |
|------|------|
| 実行時間 | 最大 90 分 |
| 出力サイズ | 最大 4 KB |
| 同時実行 | VM あたり 1 つ |
| 前提条件 | VM Agent が動作中であること |

---

## 方式 2: `az connectedmachine run-command`（Arc 対応 VM 向け）

Azure Arc に登録された VM に対して、同じく Azure API 経由でスクリプトを実行します。本 HOL のオンプレ VM は Arc 対応後にこの方式が利用可能になります。

```
ローカル PC → Azure API → Arc Agent (azcmagent) → PowerShell 実行
```

### 使用例

```powershell
# run-command create 方式（出力サイズ制限なし）
az connectedmachine run-command create `
  --resource-group rg-onprem `
  --machine-name vm-onprem-web-Arc `
  --name "check-status" `
  --script "Get-Service | Where-Object Status -eq 'Running' | Select Name, Status"

# @file パターン（スクリプトファイルを送信）
az connectedmachine run-command create `
  --resource-group rg-onprem `
  --machine-name vm-onprem-web-Arc `
  --name "run-script" `
  --script @scripts/my-check.ps1
```

### `vm run-command invoke` との違い

| 項目 | `az vm run-command invoke` | `az connectedmachine run-command create` |
|------|--------------------------|----------------------------------------|
| 対象 | Azure VM | Arc 対応 VM |
| API | Compute RP | HybridCompute RP |
| 出力制限 | 4 KB | なし（`instanceView` で取得） |
| 実行結果の保持 | なし（即時返却） | リソースとして残る（要削除） |
| 前提条件 | VM Agent | Connected Machine Agent |

---

## 方式 3: Azure Bastion（ブラウザ RDP）

Azure Portal から直接 VM に RDP 接続します。VM に Public IP や NSG の RDP 許可は不要です。

```
ブラウザ → Azure Portal → Bastion (bas-hub) → VNet ピアリング → VM
```

### 本 HOL での構成

| 項目 | 値 |
|------|-----|
| Bastion 名 | `bas-hub` |
| SKU | Basic |
| VNet | `vnet-hub` → ピアリング経由で全 Spoke VM にアクセス可能 |

### Bastion SKU による機能差

| 機能 | Basic | Standard | Premium |
|------|-------|----------|---------|
| ブラウザ RDP/SSH | ✅ | ✅ | ✅ |
| ネイティブクライアント (az network bastion tunnel) | ❌ | ✅ | ✅ |
| ファイル転送 | ❌ | ✅ | ✅ |
| Shareable Link | ❌ | ✅ | ✅ |
| Private-only 接続 | ❌ | ❌ | ✅ |

> **Note**  
> 本 HOL は Basic SKU のため、ネイティブクライアント接続は利用できません。

---

## 方式 4: Azure Bastion ネイティブクライアント（Standard 以上）

Bastion をトンネルとして使い、ローカル端末から直接 RDP/SSH 接続します。Standard SKU 以上が必要です。

```
ローカル PC → az network bastion tunnel → Bastion → VM
```

### トンネル接続の例

```powershell
# ① RDP トンネルを開く（バックグラウンド）
az network bastion tunnel `
  --name bas-hub --resource-group rg-hub `
  --target-resource-id $(az vm show -g rg-spoke1 -n vm-spoke1-test --query id -o tsv) `
  --resource-port 5985 --port 15985

# ② トンネル経由で PowerShell Remoting
$cred = Get-Credential
Enter-PSSession -ComputerName localhost -Port 15985 -Credential $cred
```

---

## 方式 5: PowerShell Remoting（WinRM over VPN）

VPN 接続済みの環境で、WinRM を使って直接 PowerShell セッションを張ります。設定が多いため、本 HOL では推奨しません。

```
ローカル PC → VPN → Azure Firewall → VM (WinRM 5985/5986)
```

### 必要な設定

| # | 設定箇所 | 内容 |
|---|---------|------|
| 1 | VM 側 | `Enable-PSRemoting -Force` |
| 2 | VM 側 | WinRM リスナーの認証設定（Basic / Kerberos） |
| 3 | NSG | WinRM ポート（5985/5986）を許可 |
| 4 | Firewall | WinRM トラフィックのネットワークルール追加 |
| 5 | クライアント側 | TrustedHosts にリモート IP を追加 |
| 6 | （推奨） | HTTPS リスナー + 証明書 の構成 |

### 設定例

```powershell
# ① VM 側：WinRM 有効化（az vm run-command で事前設定）
az vm run-command invoke -g rg-spoke1 -n vm-spoke1-test `
  --command-id RunPowerShellScript `
  --scripts "Enable-PSRemoting -Force; Set-Item WSMan:\localhost\Service\Auth\Basic -Value true"

# ② NSG ルール追加
az network nsg rule create -g rg-spoke1 --nsg-name nsg-snet-web `
  -n AllowWinRM --priority 100 `
  --destination-port-ranges 5985 5986 `
  --access Allow --protocol Tcp --direction Inbound `
  --source-address-prefixes 10.0.0.0/16

# ③ クライアント側：TrustedHosts 追加
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "10.20.1.4" -Force

# ④ 接続
$cred = Get-Credential
Enter-PSSession -ComputerName 10.20.1.4 -Credential $cred
```

---

## 本 HOL での使い分け

| 場面 | 推奨方式 | 理由 |
|------|---------|------|
| 検証スクリプト (`Verify-*.ps1`) | `az vm run-command invoke` | ネットワーク設定不要、自動化向き |
| Arc 対応 VM の検証 | `az connectedmachine run-command create` | Arc Agent 経由、出力制限なし |
| オンプレ VM の設定変更 | `az vm run-command invoke` | DC01/APP01/DB01 への設定投入 |
| GUI 操作・デバッグ | Bastion ブラウザ RDP | Basic SKU で利用可能 |
| 疎通テスト（VM 内から） | Bastion ブラウザ RDP | `Test-NetConnection` の対話実行 |

---

## 重要なポイント

- **`az vm run-command invoke` は非対話型**。出力は 4KB まで。大量の出力が必要な場合は `connectedmachine run-command create` を使う
- **Bastion Basic SKU ではネイティブクライアント接続が使えない**。Standard へのアップグレードは Bastion リソースの再作成が必要
- **WinRM はセキュリティリスクが高い**。Basic 認証 + HTTP は本番環境では使用しないこと。HTTPS + Kerberos/CredSSP を推奨
- **`connectedmachine run-command create` は実行結果がリソースとして残る**。不要になったら `--name` を指定して削除すること
- **VM Agent / Arc Agent が停止していると `run-command` は実行できない**。Agent の状態確認が先決

---

## 参考

- [Azure VM でのコマンドの実行](https://learn.microsoft.com/azure/virtual-machines/run-command-overview)
- [az vm run-command invoke リファレンス](https://learn.microsoft.com/cli/azure/vm/run-command#az-vm-run-command-invoke)
- [az connectedmachine run-command リファレンス](https://learn.microsoft.com/cli/azure/connectedmachine/run-command)
- [Azure Bastion 概要](https://learn.microsoft.com/azure/bastion/bastion-overview)
- [Bastion ネイティブクライアント接続](https://learn.microsoft.com/azure/bastion/connect-native-client-windows)
- [Bastion SKU の機能比較](https://learn.microsoft.com/azure/bastion/configuration-settings#skus)
- [PowerShell Remoting のセキュリティ考慮事項](https://learn.microsoft.com/powershell/scripting/security/remoting/winrm-security)
- [WinRM over HTTPS の構成](https://learn.microsoft.com/troubleshoot/windows-client/system-management-components/configure-winrm-for-https)
