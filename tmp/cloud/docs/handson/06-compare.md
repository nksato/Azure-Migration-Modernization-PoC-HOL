# Phase 6: 移行パターン比較・まとめ

## 目的

4 つの移行パターン（Spoke1〜4）の結果を比較し、それぞれの特徴とトレードオフを理解します。

## 比較表

| 観点 | Spoke1 (Rehost) | Spoke2 (DB PaaS) | Spoke3 (Container) | Spoke4 (Full PaaS) |
|------|-----------------|-------------------|--------------------|--------------------|
| **主要ツール** | Copilot 移行 Agent + Migrate | Copilot App Mod + DMS | Copilot App Mod + Docker | Copilot App Mod |
| **AP 変更** | なし | 接続文字列変更 | .NET 8 変換 + Docker化 | .NET 8 変換 |
| **DB 変更** | なし | PaaS化 (DMS) | PaaS化 (DMS) | PaaS化 (DMS) |
| **運用負荷** | 高（OS管理あり） | 中（Web VM の管理あり） | 低 | 低 |
| **スケーラビリティ** | 低 | 低 | 高 | 中〜高 |
| **コスト（月額）** | ~$90 | ~$42 | ~$17 | ~$25 |
| **移行難易度** | 低 | 低〜中 | 高 | 中〜高 |
| **推奨シナリオ** | 緊急移行 | DB だけ先に PaaS 化 | マイクロサービス化 | Web アプリの PaaS 化 |
| **ブラウザ確認** | Bastion→VM RDP | Bastion→VM RDP | パブリック URL | パブリック URL |

## 考察ポイント

### 1. コストと運用負荷のトレードオフ

- Rehost（Spoke1）は移行が最も簡単だが、VM の OS パッチや監視が必要
- フル PaaS（Spoke4）は初期の変換コストがかかるが、運用は Azure に任せられる

### 2. モダナイズの段階的アプローチ

```text
Spoke1 (Rehost)  →  Spoke2 (DB PaaS)  →  Spoke3/4 (フルモダナイズ)
   最小変更            DB だけ PaaS         コード変換 + PaaS/コンテナ
```

### 3. GitHub Copilot App Modernization の効果

- Spoke2: 接続文字列の変更のみ（最小限の変更）
- Spoke3/4: .NET Framework 4.8 → .NET 8 の完全変換

### 4. ネットワーク構成の比較

| Spoke | パブリックアクセス | DB 接続方式 |
|-------|-------------------|------------|
| Spoke1 | なし（Bastion 経由） | VM 間直接接続 |
| Spoke2 | なし（Bastion 経由） | Private Endpoint |
| Spoke3 | あり（Ingress URL） | Private Endpoint |
| Spoke4 | あり（App Service URL） | VNet Integration + PE |

## リソースのクリーンアップ

ハンズオン終了後、コストを抑えるためにリソースを削除します。

### Spoke リソースの削除

```powershell
# 各 Spoke のリソースを削除
az group delete --name rg-spoke1 --yes --no-wait
az group delete --name rg-spoke2 --yes --no-wait
az group delete --name rg-spoke3 --yes --no-wait
az group delete --name rg-spoke4 --yes --no-wait
```

### 全環境の削除

```powershell
# 全リソースグループを削除（ハンズオン環境全体）
az group delete --name rg-spoke1 --yes --no-wait
az group delete --name rg-spoke2 --yes --no-wait
az group delete --name rg-spoke3 --yes --no-wait
az group delete --name rg-spoke4 --yes --no-wait
az group delete --name rg-hub --yes --no-wait
az group delete --name rg-onprem --yes --no-wait
```

## まとめ

このハンズオンでは、同じアプリケーションを 4 つの異なるパターンで移行しました:

1. **Rehost**: 最も簡単だが運用負荷が高い → 緊急移行に適する
2. **DB PaaS 化**: 最小限のコード変更で DB を PaaS 化 → 段階的移行の第一歩
3. **コンテナ化**: フルモダナイズ + コンテナ → スケーラビリティ重視
4. **フル PaaS**: フルモダナイズ + PaaS → 運用負荷最小化

実際のプロジェクトでは、アプリの特性・チームのスキル・移行のタイムライン・コスト制約に応じて最適なパターンを選択してください。
