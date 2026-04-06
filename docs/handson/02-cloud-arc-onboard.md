# 02. Azure Arc 登録

移行元サーバー `DC01` / `DB01` / `APP01` を **Azure Arc** に登録し、Azure の管理プレーンから一元管理できるようにします。

> **Note**: 本ラボのサーバーは実体が **Azure VM** のため、通常のオンプレ向けオンボードではなく、  
> [Azure 仮想マシンで Azure Arc 対応サーバーを評価する](https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)  
> の手順で登録します。

## 目的

- 移行前サーバーを Azure の管理対象に統合する
- Policy / Monitor / Defender を適用できる状態にする
- オンプレミスも Azure から管理できることを体験する

## 対象サーバー

| サーバー | 役割 | Azure VM リソース名 |
|---|---|---|
| `DC01` | Active Directory / DNS | `vm-onprem-ad` |
| `DB01` | SQL Server | `vm-onprem-sql` |
| `APP01` | Web アプリ | `vm-onprem-web` |

## 前提条件

- [`00a-onprem-deploy.md`](./00a-onprem-deploy.md) が完了している
- `rg-onprem` に対象 VM が存在している
- Azure CLI / PowerShell を利用できる
- Arc 登録先リソース グループに対して必要な権限がある
  - `Azure Connected Machine Onboarding` ロール
  - 必要に応じて `Azure Connected Machine Resource Administrator` または `Contributor`
- VM から Azure Connected Machine Agent を取得できる送信接続がある  
  （制限がある場合は Microsoft Learn の記載に沿い手動配置で対応）

## 推奨手順: `Convert-VmToArc.ps1` を利用

リポジトリに同梱のスクリプトで、Azure VM の Arc 評価用準備と登録をまとめて実行できます。

```powershell
Set-Location .\infra\onprem

# 全 VM (vm-onprem-ad / vm-onprem-sql / vm-onprem-web) を Arc 対応にする
.\Convert-VmToArc.ps1 -ResourceGroupName "rg-onprem"

# 特定の VM のみ対象にする場合
.\Convert-VmToArc.ps1 -ResourceGroupName "rg-onprem" -VmNames @("vm-onprem-web")

# Arc リソースを別のリソースグループに登録する場合
.\Convert-VmToArc.ps1 -ResourceGroupName "rg-onprem" -ArcResourceGroupName "rg-arc"
```

## スクリプトの処理内容

Microsoft Learn の評価手順に沿い、各 Azure VM で次の処理を実行します。

1. `MSFT_ARC_TEST=true` を設定
2. VM 拡張機能を削除
3. `WindowsAzureGuestAgent` を無効化
4. IMDS (`169.254.169.254` / `169.254.169.253`) へのアクセスをブロック
5. Azure Connected Machine Agent をインストール
6. `azcmagent connect` で Azure Arc に登録

## 手動で実施する場合

スクリプトを使わない場合も、Microsoft Learn の評価手順に従ってください。  
Azure VM に対してそのまま `azcmagent connect` を実行すると、Azure VM として検出され失敗します。

事前に以下の準備が必要です。

- `MSFT_ARC_TEST=true` の設定
- Azure VM 拡張機能の削除
- Azure VM ゲスト エージェントの停止・無効化
- IMDS のブロック
- 上記完了後に `azcmagent connect` またはポータル生成スクリプトを実行

## 確認

```powershell
az connectedmachine list `
  --resource-group rg-onprem `
  --query "[].{name:name,status:status,os:osName}" `
  -o table
```

- Azure Arc のマシン一覧に 3 台が表示される
- ステータスが `Connected` である
- 必要に応じてタグが付与されている

## 備考: 通常のオンプレサーバーを Arc 登録する場合

実際のオンプレミスや他クラウドのサーバーでは、本ラボのような Azure VM 向け準備は不要です。  
Azure Portal でオンボーディング スクリプトを生成し、対象サーバー上で Azure Connected Machine Agent をインストール・接続します。

## 参考リンク

- [Azure portal を使用したハイブリッド マシンの接続](https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/onboard-portal)
- [Azure 仮想マシンで Azure Arc 対応サーバーを評価する](https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)

## 次のステップ

➡ [`03-cloud-hybrid-mgmt.md`](./03-cloud-hybrid-mgmt.md)
