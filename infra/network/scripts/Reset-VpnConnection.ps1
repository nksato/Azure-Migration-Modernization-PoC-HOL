# =============================================================================
# Reset-VpnConnection.ps1
# VPN 接続の軽量リセット - Connection と LGW のみ削除し、VPN Gateway は保持
#
# VPN を「ゲートウェイ配置済み・接続設定なし」のクリーン状態に戻します。
# VPN Gateway と Public IP は再作成コストが高い (~30-45 分) ため保持します。
#
# 削除対象:
#   [1/2] VPN Connection (cn-onprem-to-hub, cn-hub-to-onprem)
#   [2/2] Local Network Gateway (lgw-hub, lgw-onprem)
#
# 保持するリソース:
#   - vgw-onprem + vgw-onprem-pip1     (rg-onprem)
#   - vpngw-hub + vpngw-hub-pip1        (rg-hub)
#   - GatewaySubnet                     (両 VNet)
#   - Hub-Spoke Peering 設定
#
# 再接続するには main.bicep を再デプロイ (VPN GW は冪等、LGW+Connection のみ再作成):
#   $env:VPN_SHARED_KEY = '<your-shared-key>'
#   az deployment sub create -l japaneast -f main.bicep -p main.bicepparam
#
# 使用方法:
#   .\Reset-VpnConnection.ps1
#   .\Reset-VpnConnection.ps1 -SkipConfirmation
# =============================================================================

param(
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremGatewayName = 'vgw-onprem',
    [string]$HubGatewayName = 'vpngw-hub',
    [string]$OnpremPipName = 'vgw-onprem-pip1',
    [string]$HubPipName = 'vpngw-hub-pip1',
    [string]$OnpremConnectionName = 'cn-onprem-to-hub',
    [string]$HubConnectionName = 'cn-hub-to-onprem',
    [string]$OnpremLgwName = 'lgw-hub',
    [string]$HubLgwName = 'lgw-onprem',
    [switch]$SkipConfirmation
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# ヘルパー: 安全な削除 (リソースが存在しない場合はスキップ)
# =============================================================================
function Remove-AzResourceSafe {
    param(
        [string]$Command,
        [string]$ResourceDescription
    )
    Write-Host "  Deleting: $ResourceDescription..." -ForegroundColor Gray
    try {
        Invoke-Expression "$Command 2>`$null"
        if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
            Write-Host "  Deleted:  $ResourceDescription" -ForegroundColor Green
        } else {
            Write-Host "  Skipped:  $ResourceDescription (not found or already deleted)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Skipped:  $ResourceDescription (not found or already deleted)" -ForegroundColor DarkGray
    }
}

# =============================================================================
# 事前確認: VPN Gateway の存在チェック
# =============================================================================
Write-Host '=== VPN 接続リセット ===' -ForegroundColor Cyan
Write-Host ''
Write-Host '[事前確認] VPN Gateway を確認中...' -ForegroundColor Yellow

$onpremGw = az network vnet-gateway show -g $OnpremResourceGroup -n $OnpremGatewayName --query 'name' -o tsv 2>$null
$hubGw    = az network vnet-gateway show -g $HubResourceGroup -n $HubGatewayName --query 'name' -o tsv 2>$null

if (-not $onpremGw -and -not $hubGw) {
    Write-Host '  VPN Gateway が見つかりません。リセット不要です。' -ForegroundColor DarkGray
    return
}

Write-Host "  $OnpremGatewayName  ($OnpremResourceGroup): $(if ($onpremGw) { '検出' } else { '未検出' })" -ForegroundColor $(if ($onpremGw) { 'Green' } else { 'DarkGray' })
Write-Host "  $HubGatewayName   ($HubResourceGroup): $(if ($hubGw) { '検出' } else { '未検出' })" -ForegroundColor $(if ($hubGw) { 'Green' } else { 'DarkGray' })

# =============================================================================
# 状態確認: 接続リソースのチェック
# =============================================================================
Write-Host ''
Write-Host '[状態確認] 接続リソースを確認中...' -ForegroundColor Yellow

$cnOnprem = az network vpn-connection show -g $OnpremResourceGroup -n $OnpremConnectionName --query '{name:name, status:connectionStatus}' -o json 2>$null | ConvertFrom-Json
$cnHub    = az network vpn-connection show -g $HubResourceGroup -n $HubConnectionName --query '{name:name, status:connectionStatus}' -o json 2>$null | ConvertFrom-Json
$lgwHub   = az network local-gateway show -g $OnpremResourceGroup -n $OnpremLgwName --query 'name' -o tsv 2>$null
$lgwOnprem = az network local-gateway show -g $HubResourceGroup -n $HubLgwName --query 'name' -o tsv 2>$null

$resources = @()
if ($cnOnprem)  { $resources += "$OnpremConnectionName  ($OnpremResourceGroup) [$($cnOnprem.status)]" }
if ($cnHub)     { $resources += "$HubConnectionName  ($HubResourceGroup) [$($cnHub.status)]" }
if ($lgwHub)    { $resources += "$OnpremLgwName           ($OnpremResourceGroup)" }
if ($lgwOnprem) { $resources += "$HubLgwName        ($HubResourceGroup)" }

if ($resources.Count -eq 0) {
    Write-Host '  接続リソースが見つかりません。VPN は既にクリーン状態です。' -ForegroundColor Green
    Write-Host ''
    Write-Host 'VPN Gateway は配置済みですが、接続設定はありません。' -ForegroundColor White
    return
}

# =============================================================================
# 確認
# =============================================================================
Write-Host ''
Write-Host '削除対象:' -ForegroundColor Yellow
foreach ($r in $resources) {
    Write-Host "  - $r"
}
Write-Host ''
Write-Host '保持するリソース:' -ForegroundColor DarkGray
Write-Host "  - $OnpremGatewayName + $OnpremPipName   ($OnpremResourceGroup)"
Write-Host "  - $HubGatewayName + $HubPipName      ($HubResourceGroup)"
Write-Host ''

if (-not $SkipConfirmation) {
    $confirm = Read-Host '続行しますか? (y/N)'
    if ($confirm -notmatch '^[yY]') {
        Write-Host 'キャンセルしました。' -ForegroundColor Yellow
        return
    }
}

# =============================================================================
# [1/2] VPN Connection の削除
# =============================================================================
Write-Host ''
Write-Host '[1/2] VPN Connection を削除中...' -ForegroundColor Yellow

if ($cnOnprem) {
    Remove-AzResourceSafe `
        -Command "az network vpn-connection delete -g $OnpremResourceGroup -n $OnpremConnectionName --no-wait -o none" `
        -ResourceDescription "$OnpremConnectionName ($OnpremResourceGroup)"
}

if ($cnHub) {
    Remove-AzResourceSafe `
        -Command "az network vpn-connection delete -g $HubResourceGroup -n $HubConnectionName --no-wait -o none" `
        -ResourceDescription "$HubConnectionName ($HubResourceGroup)"
}

# Connection の削除完了を待機
if ($cnOnprem -or $cnHub) {
    Write-Host '  削除完了を待機中...' -ForegroundColor Gray
    if ($cnOnprem) { az network vpn-connection wait -g $OnpremResourceGroup -n $OnpremConnectionName --deleted 2>$null }
    if ($cnHub)    { az network vpn-connection wait -g $HubResourceGroup -n $HubConnectionName --deleted 2>$null }
    Write-Host '  VPN Connection を削除しました。' -ForegroundColor Green
}

# =============================================================================
# [2/2] Local Network Gateway の削除
# =============================================================================
Write-Host ''
Write-Host '[2/2] Local Network Gateway を削除中...' -ForegroundColor Yellow

if ($lgwHub) {
    Remove-AzResourceSafe `
        -Command "az network local-gateway delete -g $OnpremResourceGroup -n $OnpremLgwName -o none" `
        -ResourceDescription "$OnpremLgwName ($OnpremResourceGroup)"
}

if ($lgwOnprem) {
    Remove-AzResourceSafe `
        -Command "az network local-gateway delete -g $HubResourceGroup -n $HubLgwName -o none" `
        -ResourceDescription "$HubLgwName ($HubResourceGroup)"
}

# =============================================================================
# 結果サマリー
# =============================================================================
Write-Host ''
Write-Host '=== VPN 接続リセット完了 ===' -ForegroundColor Green
Write-Host ''
Write-Host '残存 VPN Gateway (再接続可能):' -ForegroundColor White
if ($onpremGw) { Write-Host "  - $OnpremGatewayName   ($OnpremResourceGroup)" }
if ($hubGw)    { Write-Host "  - $HubGatewayName    ($HubResourceGroup)" }
Write-Host ''
Write-Host '再接続するには:' -ForegroundColor White
Write-Host '  $env:VPN_SHARED_KEY = ''<your-shared-key>'''
Write-Host '  az deployment sub create -l japaneast -f main.bicep -p main.bicepparam'
