<#
.SYNOPSIS
    VPN デプロイ オーケストレーション (Nested Hyper-V 環境)
.DESCRIPTION
    3 フェーズで VPN 接続を確立する PowerShell オーケストレーションスクリプト。

    Phase 1: On-prem 側 VPN Gateway をデプロイ (onprem-gateway.bicep)
    Phase 2: Hub 側 VPN Gateway の存在確認 (既存 or main.bicep で新規作成)
    Phase 3: 双方向 S2S (IPsec) 接続を確立 (main.bicep)
             LGW + Connection を各サイドに作成

    将来的に Phase 1 を実オンプレやAWS/GCP 側のプロビジョニングに差し替え可能。
.PARAMETER Mode
    Standalone : Hub VPN Gateway を新規作成 (onprem-nested のみ使用)
    Dual       : 既存の Hub VPN Gateway を使用 (infra/network/ で作成済み)
.PARAMETER SharedKey
    VPN 認証用の共有キー。未指定の場合は環境変数 VPN_SHARED_KEY を参照。
.PARAMETER Location
    デプロイリージョン (既定: japaneast)
.PARAMETER SkipPhase1
    Phase 1 (on-prem GW) をスキップ (既にデプロイ済みの場合)
.EXAMPLE
    .\Deploy-Vpn.ps1 -Mode Dual
.EXAMPLE
    .\Deploy-Vpn.ps1 -Mode Standalone -SharedKey 'MySecretKey123!'
.EXAMPLE
    .\Deploy-Vpn.ps1 -Mode Dual -SkipPhase1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Standalone', 'Dual')]
    [string]$Mode,

    [string]$SharedKey,

    [string]$Location = 'japaneast',

    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$HubGatewayName = 'vpngw-hub',

    [switch]$SkipPhase1
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$infraDir = Split-Path $scriptDir -Parent  # network-nested/

# --- Resolve shared key ---
if (-not $SharedKey) {
    $SharedKey = $env:VPN_SHARED_KEY
}
if (-not $SharedKey) {
    throw "SharedKey is required. Pass -SharedKey or set `$env:VPN_SHARED_KEY."
}

# =============================================================================
# Phase 1: On-prem VPN Gateway
# =============================================================================
if (-not $SkipPhase1) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " Phase 1: On-prem VPN Gateway Deploy" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Deploying on-prem VPN Gateway (30-45 min)..." -ForegroundColor Yellow

    $phase1 = az deployment sub create `
        --location $Location `
        --template-file "$infraDir/onprem-gateway.bicep" `
        --parameters "$infraDir/onprem-gateway.bicepparam" `
        --query 'properties.outputs' `
        -o json | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) { throw "Phase 1 failed: on-prem VPN Gateway deployment." }

    $onpremGatewayId = $phase1.onpremVpnGatewayId.value
    $onpremGatewayPip = $phase1.onpremVpnGatewayPip.value
    Write-Host "  On-prem Gateway ID : $onpremGatewayId" -ForegroundColor Green
    Write-Host "  On-prem Gateway PIP: $onpremGatewayPip" -ForegroundColor Green
} else {
    Write-Host "`n Phase 1: Skipped (on-prem GW already deployed)" -ForegroundColor DarkGray
}

# =============================================================================
# Phase 2: Hub VPN Gateway verification
# =============================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Phase 2: Hub VPN Gateway Check" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$hubGwExists = az network vnet-gateway show `
    -g $HubResourceGroup -n $HubGatewayName `
    --query 'provisioningState' -o tsv 2>$null

if ($hubGwExists -eq 'Succeeded') {
    Write-Host "  Hub VPN Gateway '$HubGatewayName' exists (Succeeded)" -ForegroundColor Green
    if ($Mode -eq 'Standalone') {
        Write-Host "  Mode=Standalone but Hub GW already exists. Reusing." -ForegroundColor Yellow
    }
} else {
    if ($Mode -eq 'Dual') {
        throw "Mode=Dual but Hub VPN Gateway '$HubGatewayName' not found. Deploy infra/network/ first or use Mode=Standalone."
    }
    Write-Host "  Hub VPN Gateway not found. Will be created in Phase 3." -ForegroundColor Yellow
}

# =============================================================================
# Phase 3: Establish VPN connections (full deployment)
# =============================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Phase 3: S2S Connection Establishment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$createHub = if ($Mode -eq 'Standalone' -and $hubGwExists -ne 'Succeeded') { 'true' } else { 'false' }

Write-Host "  createHubVpnGateway = $createHub" -ForegroundColor Gray
Write-Host "  Deploying S2S connections (LGW + IPsec)..." -ForegroundColor Yellow

$env:VPN_SHARED_KEY = $SharedKey

$phase3 = az deployment sub create `
    --location $Location `
    --template-file "$infraDir/main.bicep" `
    --parameters "$infraDir/main.bicepparam" `
    --parameters createHubVpnGateway=$createHub `
    --query 'properties.outputs' `
    -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) { throw "Phase 3 failed: VPN connection deployment." }

# =============================================================================
# Summary
# =============================================================================
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " VPN Deployment Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Mode             : $Mode"
Write-Host "  On-prem Gateway  : $($phase3.onpremVpnGatewayId.value)"
Write-Host "  On-prem PIP      : $($phase3.onpremVpnGatewayPip.value)"
Write-Host "  Hub Gateway      : $($phase3.hubVpnGatewayId.value)"
Write-Host "  Hub PIP          : $($phase3.hubVpnGatewayPip.value)"
Write-Host "  Connection (O->H): $($phase3.connectionOnpremToHubId.value)"
Write-Host "  Connection (H->O): $($phase3.connectionHubToOnpremId.value)"
Write-Host ""
Write-Host "Run Verify-VpnConnection.ps1 to validate connectivity." -ForegroundColor Cyan
