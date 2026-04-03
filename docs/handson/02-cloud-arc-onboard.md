# 02. Azure Arc 登録（評価 / オプション）

このフェーズでは、移行元サーバー `DC01` / `DB01` / `APP01` を **Azure Arc** に登録し、Azure の管理プレーンから一元管理できるようにします。

> **重要**: この疑似オンプレ環境のサーバーは実体として **Azure VM** です。  
> そのため、Azure Arc 対応サーバーとして扱うには、通常のオンプレ/他クラウド向けオンボード手順ではなく、Microsoft Learn の  
> [Azure 仮想マシンで Azure Arc 対応サーバーを評価する](https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)  
> に沿った **評価・テスト用の手順** で実施します。運用用途ではなく、ハンズオン評価用途として扱ってください。

## 目的

- 移行前サーバーを Azure 管理へ統合する
- Policy / Monitor / Defender の適用対象にする
- 「オンプレも Azure から管理できる」状態を体験する

## 対象サーバー

| サーバー | 役割 | Azure VM リソース名 |
|---|---|---|
| `DC01` | Active Directory / DNS | `OnPrem-AD` |
| `DB01` | SQL Server | `OnPrem-SQL` |
| `APP01` | Web アプリ | `OnPrem-Web` |

## 前提条件

- [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) が完了している
- `rg-onprem` に対象 VM が存在している
- Azure CLI / PowerShell を利用できる
- Arc 登録先リソース グループに対して必要な権限がある
  - `Azure Connected Machine Onboarding` ロール
  - 必要に応じて `Azure Connected Machine Resource Administrator` または `Contributor`
- VM から Azure Connected Machine Agent を取得できる送信接続がある  
  （制限がある場合は、Microsoft Learn の記載どおり手動配置で対応）

## 推奨手順: `Enable-ArcOnVMs.ps1` を利用

このリポジトリでは、Azure VM を Arc 評価用に準備する処理をまとめたスクリプトを用意しています。

```powershell
Set-Location .\infra\onprem

# 全 VM (OnPrem-AD / OnPrem-SQL / OnPrem-Web) を Arc 対応にする
.\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onprem"

# 特定の VM のみ Arc 対応にする場合
.\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onprem" -VmNames @("OnPrem-Web")

# Arc リソースを別のリソースグループに登録する場合
.\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onprem" -ArcResourceGroupName "rg-arc"
```

## スクリプトが実施する内容

Microsoft Learn の評価手順に沿って、各 Azure VM で次の処理を自動化します。

1. `MSFT_ARC_TEST=true` を設定
2. VM 拡張機能を削除
3. `WindowsAzureGuestAgent` を無効化
4. IMDS (`169.254.169.254` / `169.254.169.253`) へのアクセスをブロック
5. Azure Connected Machine Agent をインストール
6. `azcmagent connect` で Azure Arc に登録

## 手動で実施する場合のポイント

スクリプトを使わず手動で行う場合も、必ず Microsoft Learn の評価手順に従ってください。
通常の Azure VM に対してそのまま `azcmagent connect` を実行すると、Azure VM として検出されて失敗します。

特に以下の準備が必要です。

- `MSFT_ARC_TEST=true` の設定
- Azure VM 拡張機能の削除
- Azure VM ゲスト エージェントの停止 / 無効化
- IMDS のブロック
- その後にポータル生成スクリプトまたは `azcmagent connect` を実行

## 確認ポイント

```powershell
az connectedmachine list `
  --resource-group rg-onprem `
  --query "[].{name:name,status:status,os:osName}" `
  -o table
```

確認事項:

- `Azure Arc` のマシン一覧に 3 台が見える
- ステータスが `Connected`
- 必要に応じてタグが付与されている

## 参考情報: 通常のオンプレサーバーを Arc 登録する場合

実際のオンプレミス サーバーや他クラウド上のサーバーを Azure Arc に登録する場合は、このハンズオンのような **Azure VM 向け評価手順** は不要です。
通常は Azure Portal でオンボーディング スクリプトを生成し、対象サーバー上で Azure Connected Machine Agent をインストールして `azcmagent connect` を実行します。

参考:
- [Azure portal を使用したハイブリッド マシンの接続](https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/onboard-portal)
- [Azure 仮想マシンで Azure Arc 対応サーバーを評価する](https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)

> つまり、このハンズオンでは **Azure VM を疑似的にオンプレサーバーとして評価するための特別な手順** を使っており、一般的な Arc 登録方法とは少し異なります。

## 次のステップ

➡ [`03-cloud-hybrid-mgmt.md`](./03-cloud-hybrid-mgmt.md)
