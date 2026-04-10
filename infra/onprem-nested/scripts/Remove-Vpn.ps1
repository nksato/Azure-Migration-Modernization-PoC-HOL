# =============================================================================
# Remove-Vpn.ps1
# VPN connection cleanup - removes all resources created by vpn-deploy.bicep
#
# Deletion order (reverse of deployment):
#   [1/5] VPN Connections (both sides)
#   [2/5] On-prem VPN Gateway (~10-15 min)
#   [3/5] On-prem VPN Gateway Public IP
#   [4/5] Cloud routes from on-prem route table
#   [5/5] GatewaySubnet from on-prem VNet
#
# Note: Hub VPN Gateway (vpngw-hub) is NOT deleted - it belongs to the cloud
#       environment (Azure-Migration-Modernization-PoC-HOL).
#
# Usage:
#   .\Remove-Vpn.ps1
#   .\Remove-Vpn.ps1 -SkipConfirmation
# =============================================================================

param(
    [string]$OnpremResourceGroup = 'rg-onprem-migration',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremVnetName = 'vnet-onprem',
    [string]$RouteTableName = 'rt-block-internet',
    [string[]]$CloudAddressPrefixes = @(
        '10.10.0.0/16'
        '10.20.0.0/16'
        '10.21.0.0/16'
        '10.22.0.0/16'
        '10.23.0.0/16'
    ),
    [switch]$SkipConfirmation
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# Helper: safe delete (skip if resource doesn't exist)
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
# Pre-flight: show what will be deleted
# =============================================================================
Write-Host '=== VPN Cleanup ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Resources to delete:' -ForegroundColor Yellow
Write-Host "  [1/5] cn-onprem-to-hub    ($OnpremResourceGroup)"
Write-Host "  [1/5] cn-hub-to-onprem    ($HubResourceGroup)"
Write-Host "  [2/5] vpngw-onprem        ($OnpremResourceGroup)  ~10-15 min"
Write-Host "  [3/5] pip-vpngw-onprem    ($OnpremResourceGroup)"
Write-Host "  [4/5] VPN routes x$($CloudAddressPrefixes.Count)       ($RouteTableName)"
Write-Host "  [5/5] GatewaySubnet       ($OnpremVnetName)"
Write-Host ''
Write-Host 'NOT deleted:' -ForegroundColor DarkGray
Write-Host "  vpngw-hub                 ($HubResourceGroup) - cloud environment resource"
Write-Host ''

if (-not $SkipConfirmation) {
    $confirm = Read-Host 'Continue? (y/N)'
    if ($confirm -notmatch '^[yY]') {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# =============================================================================
# [1/5] Delete VPN Connections
# =============================================================================
Write-Host ''
Write-Host '[1/5] Deleting VPN connections...' -ForegroundColor Yellow

Remove-AzResourceSafe `
    -Command "az network vpn-connection delete -g $OnpremResourceGroup -n cn-onprem-to-hub --no-wait -o none" `
    -ResourceDescription "cn-onprem-to-hub ($OnpremResourceGroup)"

Remove-AzResourceSafe `
    -Command "az network vpn-connection delete -g $HubResourceGroup -n cn-hub-to-onprem --no-wait -o none" `
    -ResourceDescription "cn-hub-to-onprem ($HubResourceGroup)"

# Wait for connection deletions to complete
Write-Host '  Waiting for connection deletions...' -ForegroundColor Gray
az network vpn-connection wait -g $OnpremResourceGroup -n cn-onprem-to-hub --deleted 2>$null
az network vpn-connection wait -g $HubResourceGroup -n cn-hub-to-onprem --deleted 2>$null
Write-Host '  VPN connections deleted.' -ForegroundColor Green

# =============================================================================
# [2/5] Delete On-prem VPN Gateway (takes ~10-15 min)
# =============================================================================
Write-Host ''
Write-Host '[2/5] Deleting on-prem VPN Gateway (vpngw-onprem)...' -ForegroundColor Yellow
Write-Host '  This takes ~10-15 minutes. Please wait...' -ForegroundColor Gray

$gwExists = az network vnet-gateway show -g $OnpremResourceGroup -n vpngw-onprem --query 'name' -o tsv 2>$null
if ($gwExists) {
    az network vnet-gateway delete -g $OnpremResourceGroup -n vpngw-onprem -o none
    Write-Host "  VPN Gateway 'vpngw-onprem' deleted." -ForegroundColor Green
} else {
    Write-Host "  VPN Gateway 'vpngw-onprem' not found. Skipping." -ForegroundColor DarkGray
}

# =============================================================================
# [3/5] Delete Public IP
# =============================================================================
Write-Host ''
Write-Host '[3/5] Deleting Public IP (pip-vpngw-onprem)...' -ForegroundColor Yellow

Remove-AzResourceSafe `
    -Command "az network public-ip delete -g $OnpremResourceGroup -n pip-vpngw-onprem -o none" `
    -ResourceDescription "pip-vpngw-onprem ($OnpremResourceGroup)"

# =============================================================================
# [4/5] Delete cloud routes from on-prem route table
# =============================================================================
Write-Host ''
Write-Host "[4/5] Deleting VPN routes from '$RouteTableName'..." -ForegroundColor Yellow

foreach ($prefix in $CloudAddressPrefixes) {
    # Route name matches Bicep: vpn-${replace(replace(prefix, '.', '-'), '/', '-')}
    $routeName = 'vpn-' + ($prefix -replace '\.', '-' -replace '/', '-')

    Remove-AzResourceSafe `
        -Command "az network route-table route delete -g $OnpremResourceGroup --route-table-name $RouteTableName -n $routeName -o none" `
        -ResourceDescription "$routeName ($prefix)"
}

# =============================================================================
# [5/5] Delete GatewaySubnet
# =============================================================================
Write-Host ''
Write-Host "[5/5] Deleting GatewaySubnet from '$OnpremVnetName'..." -ForegroundColor Yellow

Remove-AzResourceSafe `
    -Command "az network vnet subnet delete -g $OnpremResourceGroup --vnet-name $OnpremVnetName -n GatewaySubnet -o none" `
    -ResourceDescription "GatewaySubnet ($OnpremVnetName)"

# =============================================================================
# Summary
# =============================================================================
$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed

Write-Host ''
Write-Host '=== VPN Cleanup Complete ===' -ForegroundColor Green
Write-Host "  Elapsed: $($elapsed.ToString('mm\:ss'))" -ForegroundColor White
Write-Host ''
Write-Host 'To redeploy:' -ForegroundColor White
Write-Host '  $env:VPN_SHARED_KEY = ''<your-shared-key>'''
Write-Host '  az deployment sub create -l japaneast -f vpn-deploy.bicep -p vpn-deploy.bicepparam'
