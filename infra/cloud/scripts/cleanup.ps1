# ============================================================
# Full Resource Cleanup Script
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

Write-Output ''
Write-Output '--- [1/2] Resource Groups ---'
foreach ($rg in $targetRgs) {
    $exists = az group exists --name $rg | ConvertFrom-Json
    if ($exists) {
        if (-not $Force) {
            $confirm = Read-Host "Delete resource group '$rg'? (y/N)"
            if ($confirm -ne 'y') {
                Write-Output "  SKIP: $rg (user cancelled)"
                continue
            }
        }
        az group delete --name $rg --yes --no-wait
        Write-Output "  DELETE: $rg (async)"
    } else {
        Write-Output "  SKIP: $rg (not found)"
    }
}

# ============================================================
# Delete subscription-scoped policy assignments
# (Only targets policies created by this HOL — does not affect pre-existing policies)
# ============================================================
Write-Output ''
Write-Output '--- [2/2] Policy Assignments (subscription scope) ---'
if ($SpokesOnly) {
    Write-Output '  SKIP: -SpokesOnly specified, policies not deleted.'
} else {
    $holPolicies = @(
        'policy-allowed-locations'
        'policy-storage-no-public'
        'policy-sql-auditing'
        'policy-sql-no-public'
        'policy-require-env-tag'
        'policy-mgmt-ports-audit'
        'policy-appservice-no-public'
        'SecurityCenterBuiltIn'
        'SqlVmAndArcSqlServersProtection'
    )

    $deleted = 0
    foreach ($name in $holPolicies) {
        $exists = az policy assignment show --name $name 2>$null
        if ($LASTEXITCODE -eq 0) {
            az policy assignment delete --name $name
            Write-Output "  DELETE: $name"
            $deleted++
        }
    }
    if ($deleted -eq 0) {
        Write-Output '  No HOL policy assignments found.'
    } else {
        Write-Output "  $deleted policy assignment(s) deleted."
    }
}

Write-Output ''
Write-Output '=== Cleanup complete. Resource group deletion may take several minutes. ==='
