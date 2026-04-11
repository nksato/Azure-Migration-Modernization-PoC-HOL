# =============================================================================
# Remove-Vpn.ps1
# VPN connection cleanup - removes all resources created by main.bicep
#
# Deletion order (reverse of deployment):
#   [1/7] VPN Connections (both sides)
#   [2/7] Local Network Gateways (both sides)
#   [3/7] On-prem VPN Gateway (~10-15 min)
#   [4/7] On-prem VPN Gateway Public IP
#   [5/7] Hub VPN Gateway + PIP (only with -IncludeHubGateway, ~10-15 min)
#   [6/7] Cloud routes from on-prem route table
#   [7/7] GatewaySubnet from on-prem VNet
#
# Note: Hub VPN Gateway (vpngw-hub) is NOT deleted by default.
#       Use -IncludeHubGateway for standalone cleanup (onprem-nested only).
#
# Usage:
#   .\Remove-Vpn.ps1                          # Dual mode (keep Hub GW)
#   .\Remove-Vpn.ps1 -IncludeHubGateway       # Standalone mode (delete Hub GW)
#   .\Remove-Vpn.ps1 -SkipConfirmation
# =============================================================================

param(
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
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
    [switch]$IncludeHubGateway,
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
$totalSteps = if ($IncludeHubGateway) { 7 } else { 6 }

Write-Host '=== VPN Cleanup ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Resources to delete:' -ForegroundColor Yellow
Write-Host "  [1/$totalSteps] cn-onprem-nested-to-hub    ($OnpremResourceGroup)"
Write-Host "  [1/$totalSteps] cn-hub-to-onprem-nested    ($HubResourceGroup)"
Write-Host "  [2/$totalSteps] lgw-hub                    ($OnpremResourceGroup)"
Write-Host "  [2/$totalSteps] lgw-onprem-nested          ($HubResourceGroup)"
Write-Host "  [3/$totalSteps] vgw-onprem          ($OnpremResourceGroup)  ~10-15 min"
Write-Host "  [4/$totalSteps] vgw-onprem-pip1     ($OnpremResourceGroup)"
if ($IncludeHubGateway) {
    Write-Host "  [5/$totalSteps] vpngw-hub           ($HubResourceGroup)  ~10-15 min" -ForegroundColor Yellow
    Write-Host "  [5/$totalSteps] vpngw-hub-pip1      ($HubResourceGroup)" -ForegroundColor Yellow
    Write-Host "  [5/$totalSteps] lgw-onprem          ($HubResourceGroup)" -ForegroundColor Yellow
}
$routeStep = if ($IncludeHubGateway) { 6 } else { 5 }
$snetStep  = if ($IncludeHubGateway) { 7 } else { 6 }
Write-Host "  [$routeStep/$totalSteps] VPN routes x$($CloudAddressPrefixes.Count)       ($RouteTableName)"
Write-Host "  [$snetStep/$totalSteps] GatewaySubnet       ($OnpremVnetName)"
Write-Host ''
if (-not $IncludeHubGateway) {
    Write-Host 'NOT deleted:' -ForegroundColor DarkGray
    Write-Host "  vpngw-hub                 ($HubResourceGroup) - use -IncludeHubGateway to delete"
    Write-Host ''
}

if (-not $SkipConfirmation) {
    $confirm = Read-Host 'Continue? (y/N)'
    if ($confirm -notmatch '^[yY]') {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# =============================================================================
# [1] Delete VPN Connections
# =============================================================================
Write-Host ''
Write-Host '[1] Deleting VPN connections...' -ForegroundColor Yellow

Remove-AzResourceSafe `
    -Command "az network vpn-connection delete -g $OnpremResourceGroup -n cn-onprem-nested-to-hub --no-wait -o none" `
    -ResourceDescription "cn-onprem-nested-to-hub ($OnpremResourceGroup)"

Remove-AzResourceSafe `
    -Command "az network vpn-connection delete -g $HubResourceGroup -n cn-hub-to-onprem-nested --no-wait -o none" `
    -ResourceDescription "cn-hub-to-onprem-nested ($HubResourceGroup)"

# Wait for connection deletions to complete
Write-Host '  Waiting for connection deletions...' -ForegroundColor Gray
az network vpn-connection wait -g $OnpremResourceGroup -n cn-onprem-nested-to-hub --deleted 2>$null
az network vpn-connection wait -g $HubResourceGroup -n cn-hub-to-onprem-nested --deleted 2>$null
Write-Host '  VPN connections deleted.' -ForegroundColor Green

# =============================================================================
# [2] Delete Local Network Gateways
# =============================================================================
Write-Host ''
Write-Host '[2] Deleting Local Network Gateways...' -ForegroundColor Yellow

Remove-AzResourceSafe `
    -Command "az network local-gateway delete -g $OnpremResourceGroup -n lgw-hub -o none" `
    -ResourceDescription "lgw-hub ($OnpremResourceGroup)"

Remove-AzResourceSafe `
    -Command "az network local-gateway delete -g $HubResourceGroup -n lgw-onprem-nested -o none" `
    -ResourceDescription "lgw-onprem-nested ($HubResourceGroup)"

# =============================================================================
# [3] Delete On-prem VPN Gateway (takes ~10-15 min)
# =============================================================================
Write-Host ''
Write-Host '[3] Deleting on-prem VPN Gateway (vgw-onprem)...' -ForegroundColor Yellow
Write-Host '  This takes ~10-15 minutes. Please wait...' -ForegroundColor Gray

$gwExists = az network vnet-gateway show -g $OnpremResourceGroup -n vgw-onprem --query 'name' -o tsv 2>$null
if ($gwExists) {
    az network vnet-gateway delete -g $OnpremResourceGroup -n vgw-onprem -o none
    Write-Host "  VPN Gateway 'vgw-onprem' deleted." -ForegroundColor Green
} else {
    Write-Host "  VPN Gateway 'vgw-onprem' not found. Skipping." -ForegroundColor DarkGray
}

# =============================================================================
# [4] Delete Public IP
# =============================================================================
Write-Host ''
Write-Host '[4] Deleting Public IP (vgw-onprem-pip1)...' -ForegroundColor Yellow

Remove-AzResourceSafe `
    -Command "az network public-ip delete -g $OnpremResourceGroup -n vgw-onprem-pip1 -o none" `
    -ResourceDescription "vgw-onprem-pip1 ($OnpremResourceGroup)"

# =============================================================================
# [5] Delete Hub VPN Gateway + PIP + LGW (standalone mode only)
# =============================================================================
if ($IncludeHubGateway) {
    Write-Host ''
    Write-Host "[5/$totalSteps] Deleting Hub VPN Gateway (vpngw-hub)..." -ForegroundColor Yellow
    Write-Host '  This takes ~10-15 minutes. Please wait...' -ForegroundColor Gray

    $hubGwExists = az network vnet-gateway show -g $HubResourceGroup -n vpngw-hub --query 'name' -o tsv 2>$null
    if ($hubGwExists) {
        az network vnet-gateway delete -g $HubResourceGroup -n vpngw-hub -o none
        Write-Host "  VPN Gateway 'vpngw-hub' deleted." -ForegroundColor Green
    } else {
        Write-Host "  VPN Gateway 'vpngw-hub' not found. Skipping." -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "  Deleting Hub PIP (vpngw-hub-pip1)..." -ForegroundColor Yellow

    Remove-AzResourceSafe `
        -Command "az network public-ip delete -g $HubResourceGroup -n vpngw-hub-pip1 -o none" `
        -ResourceDescription "vpngw-hub-pip1 ($HubResourceGroup)"

    Write-Host ''
    Write-Host "  Deleting Hub LGW (lgw-onprem)..." -ForegroundColor Yellow

    Remove-AzResourceSafe `
        -Command "az network local-gateway delete -g $HubResourceGroup -n lgw-onprem -o none" `
        -ResourceDescription "lgw-onprem ($HubResourceGroup)"
}

# =============================================================================
# [N-1/N] Delete cloud routes from on-prem route table
# =============================================================================
Write-Host ''
Write-Host "[$routeStep/$totalSteps] Deleting VPN routes from '$RouteTableName'..." -ForegroundColor Yellow

foreach ($prefix in $CloudAddressPrefixes) {
    # Route name matches Bicep: vpn-${replace(replace(prefix, '.', '-'), '/', '-')}
    $routeName = 'vpn-' + ($prefix -replace '\.', '-' -replace '/', '-')

    Remove-AzResourceSafe `
        -Command "az network route-table route delete -g $OnpremResourceGroup --route-table-name $RouteTableName -n $routeName -o none" `
        -ResourceDescription "$routeName ($prefix)"
}

# =============================================================================
# [N/N] Delete GatewaySubnet
# =============================================================================
Write-Host ''
Write-Host "[$snetStep/$totalSteps] Deleting GatewaySubnet from '$OnpremVnetName'..." -ForegroundColor Yellow

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
