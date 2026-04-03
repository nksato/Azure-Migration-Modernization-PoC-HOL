# ============================================================
# 全リソースクリーンアップスクリプト
# ============================================================

param(
    [switch]$SpokesOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Output '=== Azure Migration PoC Cleanup ==='

$spokeRgs = @('rg-spoke1', 'rg-spoke2', 'rg-spoke3', 'rg-spoke4')
$allRgs = $spokeRgs + @('rg-hub', 'rg-onprem')

$targetRgs = if ($SpokesOnly) { $spokeRgs } else { $allRgs }

foreach ($rg in $targetRgs) {
    $exists = az group exists --name $rg | ConvertFrom-Json
    if ($exists) {
        if (-not $Force) {
            $confirm = Read-Host "Delete resource group '$rg'? (y/N)"
            if ($confirm -ne 'y') {
                Write-Output "Skipping $rg"
                continue
            }
        }
        Write-Output "Deleting $rg..."
        az group delete --name $rg --yes --no-wait
        Write-Output "$rg deletion initiated."
    } else {
        Write-Output "$rg does not exist, skipping."
    }
}

Write-Output '=== Cleanup initiated. Resource group deletion may take several minutes. ==='
