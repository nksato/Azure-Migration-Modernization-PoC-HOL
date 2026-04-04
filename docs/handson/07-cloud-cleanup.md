# 07. 環境クリーンアップ

ハンズオン終了後、不要な課金を避けるために作成したリソースをすべて削除します。

## 目的

- HOL で作成したリソースグループを削除する
- HOL で作成したサブスクリプションスコープのポリシー割り当てを削除する
- HOL 以前から存在するリソースには影響を与えない

---

## 削除対象

### リソースグループ

| リソースグループ | 内容 |
|---|---|
| `rg-spoke1` | Spoke1: Rehost（VM 移行） |
| `rg-spoke2` | Spoke2: DB PaaS 化 |
| `rg-spoke3` | Spoke3: コンテナ化 |
| `rg-spoke4` | Spoke4: フル PaaS 化 |
| `rg-hub` | Hub: Firewall / Bastion / VPN GW / DNS 等 |
| `rg-onprem` | 疑似オンプレ: DC01 / DB01 / APP01 |

### ポリシー割り当て（サブスクリプションスコープ）

| ポリシー名 | 表示名 |
|---|---|
| `policy-allowed-locations` | Allowed locations |
| `policy-storage-no-public` | Storage accounts should disable public network access |
| `policy-sql-auditing` | SQL servers should have auditing enabled |
| `policy-sql-no-public` | Azure SQL Database should disable public network access |
| `policy-require-env-tag` | Require Environment tag on resource groups |
| `policy-mgmt-ports-audit` | Management ports should be closed on VMs |
| `policy-appservice-no-public` | App Service should disable public network access |
| `SecurityCenterBuiltIn` | Microsoft Defender for Cloud (Security Center) |
| `SqlVmAndArcSqlServersProtection` | SQL VM & Arc SQL Servers Protection |

> **安全設計**: クリーンアップスクリプトは上記のポリシー名を明示的に指定して削除します。HOL 以前に設定されたポリシーは削除されません。

---

## 方法 A: クリーンアップスクリプトを使う（推奨）

`infra/cloud/scripts/cleanup.ps1` を使用すると、リソースグループとポリシー割り当てをまとめて削除できます。

### 全リソース削除（確認あり）

```powershell
.\infra\cloud\scripts\cleanup.ps1
```

各リソースグループに対して `Delete resource group 'rg-xxx'? (y/N)` の確認プロンプトが表示されます。

### 全リソース削除（確認なし）

```powershell
.\infra\cloud\scripts\cleanup.ps1 -Force
```

### Spoke リソースグループのみ削除

```powershell
.\infra\cloud\scripts\cleanup.ps1 -SpokesOnly
```

`rg-spoke1` ～ `rg-spoke4` のみ削除します。Hub・オンプレ環境およびポリシー割り当ては残ります。  
移行パターンをやり直す場合に便利です。

### スクリプトの出力例

```
=== Azure Migration PoC Cleanup ===

--- [1/2] Resource Groups ---
  DELETE: rg-spoke1 (async)
  DELETE: rg-spoke2 (async)
  SKIP: rg-spoke3 (not found)
  SKIP: rg-spoke4 (not found)
  DELETE: rg-hub (async)
  DELETE: rg-onprem (async)

--- [2/2] Policy Assignments (subscription scope) ---
  DELETE: policy-allowed-locations
  DELETE: policy-storage-no-public
  DELETE: policy-sql-auditing
  DELETE: policy-sql-no-public
  DELETE: policy-require-env-tag
  DELETE: policy-mgmt-ports-audit
  DELETE: policy-appservice-no-public
  DELETE: SecurityCenterBuiltIn
  DELETE: SqlVmAndArcSqlServersProtection
  9 policy assignment(s) deleted.

=== Cleanup complete. Resource group deletion may take several minutes. ===
```

---

## 方法 B: Azure Portal から手動で削除する

1. [Azure Portal](https://portal.azure.com) にサインイン
2. **リソース グループ** を検索して開く
3. 以下のリソースグループを 1 つずつ選択し、**[リソース グループの削除]** をクリック:
   - `rg-spoke1` ～ `rg-spoke4`
   - `rg-hub`
   - `rg-onprem`
4. リソースグループ名を入力して削除を確認
5. **ポリシー** → **[割り当て]** を開き、上記ポリシー一覧の各項目を選択して **[割り当ての削除]** をクリック

---

## 削除にかかる時間

| リソース | 目安 |
|---|---|
| Spoke リソースグループ（VM なし） | 数分 |
| `rg-hub`（VPN GW / Firewall 含む） | 10 ～ 20 分 |
| `rg-onprem`（VM 3 台含む） | 5 ～ 10 分 |
| ポリシー割り当て | 数秒 |

> リソースグループの削除は非同期で実行されます。スクリプト終了後もバックグラウンドで削除処理が継続します。

---

## 削除の確認

すべてのリソースグループが削除されたことを確認します。

```powershell
az group list --query "[?starts_with(name, 'rg-spoke') || name == 'rg-hub' || name == 'rg-onprem'].name" -o tsv
```

出力が空であれば、すべてのリソースグループが削除済みです。

ポリシー割り当ての確認:

```powershell
az policy assignment list --query "[?starts_with(name, 'policy-') || name == 'SecurityCenterBuiltIn' || name == 'SqlVmAndArcSqlServersProtection'].name" -o tsv
```

出力が空であれば、HOL のポリシー割り当てはすべて削除済みです。
