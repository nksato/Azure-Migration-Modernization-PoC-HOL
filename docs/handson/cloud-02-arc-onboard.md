# Phase 2: Azure Arc 接続

このフェーズでは、移行元サーバー `DC01` / `DB01` / `APP01` を **Azure Arc** に登録し、Azure の管理プレーンから一元管理できるようにします。

## 目的

- 移行前サーバーを Azure 管理へ統合する
- Policy / Monitor / Defender の適用対象にする
- 「オンプレも Azure から管理できる」状態を作る

## 対象サーバー

| サーバー | 役割 |
|---|---|
| `DC01` | Active Directory / DNS |
| `DB01` | SQL Server |
| `APP01` | Web アプリ |

## 概要手順

1. Arc 登録用のサービスプリンシパルを準備
2. 各 VM に Azure Connected Machine Agent を導入
3. Azure Arc に接続
4. Azure Portal で `Connected` 状態を確認

## 実行イメージ

```powershell
az ad sp create-for-rbac `
  --name "sp-arc-onboarding" `
  --role "Azure Connected Machine Onboarding"
```

各 VM では `azcmagent connect` を利用して接続します。

## 確認ポイント

- `Azure Arc` のマシン一覧に 3 台が見える
- ステータスが `Connected`
- 必要に応じてタグが付与されている

## 次のステップ

➡ [`cloud-03-hybrid-mgmt.md`](./cloud-03-hybrid-mgmt.md)
