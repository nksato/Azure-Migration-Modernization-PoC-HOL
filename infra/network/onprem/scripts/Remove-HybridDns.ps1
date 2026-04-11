<#
.SYNOPSIS
    Hybrid DNS 構成を削除する (Setup-HybridDns.ps1 の逆操作)
.DESCRIPTION
    Setup-HybridDns.ps1 で作成した DNS 設定をすべて削除する。
    ローカル PC から Azure CLI + az vm run-command で実行する。

    削除対象:
      [1/4] [On-prem] DC01 条件付きフォワーダー (privatelink.database.windows.net, azure.internal)
      [2/4] [Cloud]   Forwarding Ruleset VNet リンク (Hub + Spoke)
      [3/4] [Cloud]   DNS Forwarding Ruleset (dnsrs-hub) — ルール含む
      [4/4] [Cloud]   Private DNS Zone: azure.internal (存在する場合のみ自動削除)

    ※ Hub DNS Resolver (dnspr-hub) は削除しない (他で共有)

    前提:
      - Azure CLI ログイン済み (az login)
      - ローカル PC から実行
.EXAMPLE
    .\Remove-HybridDns.ps1
.EXAMPLE
    .\Remove-HybridDns.ps1 -SkipConfirmation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$VmName = 'vm-onprem-ad',
    [string]$RulesetName = 'dnsrs-hub',
    [switch]$SkipConfirmation
)

$ErrorActionPreference = 'Stop'

$privateLinkZones = @(
    'privatelink.database.windows.net'
)
$cloudVmDnsZone = 'azure.internal'

# =============================================================================
Write-Host ''
Write-Host '=== Remove Hybrid DNS Configuration ===' -ForegroundColor Cyan
Write-Host ''

# =============================================================================
# 状態確認: 削除対象リソースのチェック
# =============================================================================
Write-Host '[状態確認] 削除対象リソースを確認中...' -ForegroundColor Yellow

$targets = @()

# DC 条件付きフォワーダー (存在確認は削除時に行う)
$targets += "DC01 conditional forwarders ($($privateLinkZones -join ', '), $cloudVmDnsZone)"

# Forwarding Ruleset
$existingRuleset = az dns-resolver forwarding-ruleset show `
    -g $HubResourceGroup -n $RulesetName --query 'name' -o tsv 2>$null
if ($existingRuleset) { $targets += "Forwarding Ruleset '$RulesetName' + rules + VNet links" }

# Private DNS Zone
$existingZone = az network private-dns zone show `
    -g $HubResourceGroup -n $cloudVmDnsZone --query 'name' -o tsv 2>$null
if ($existingZone) { $targets += "Private DNS Zone '$cloudVmDnsZone' + VNet links" }

if ($targets.Count -eq 0) {
    Write-Host '  削除対象リソースが見つかりません。DNS は既にクリーン状態です。' -ForegroundColor Green
    return
}

Write-Host ''
Write-Host '削除対象:' -ForegroundColor Yellow
foreach ($t in $targets) {
    Write-Host "  - $t"
}
Write-Host ''
Write-Host '保持するリソース:' -ForegroundColor DarkGray
Write-Host '  - Hub DNS Resolver (dnspr-hub)'
Write-Host '  - Hub DNS Resolver inbound/outbound endpoints'
Write-Host ''

if (-not $SkipConfirmation) {
    $confirm = Read-Host '続行しますか? (y/N)'
    if ($confirm -notmatch '^[yY]') {
        Write-Host 'キャンセルしました。' -ForegroundColor Yellow
        return
    }
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# =============================================================================
# [1/4] DC01: 条件付きフォワーダーを削除
# =============================================================================
Write-Host ''
Write-Host '[1/4] [On-prem] DC01 の条件付きフォワーダーを削除中...' -ForegroundColor Yellow

$allZones = @($privateLinkZones) + @($cloudVmDnsZone)
$zonesArrayStr = ($allZones | ForEach-Object { "'$_'" }) -join ','

$script = @"
`$zones = @($zonesArrayStr)
foreach (`$zone in `$zones) {
    `$existing = Get-DnsServerZone -Name `$zone -ErrorAction SilentlyContinue
    if (`$existing -and `$existing.ZoneType -eq 'Forwarder') {
        Remove-DnsServerZone -Name `$zone -Force
        Write-Output "  `$zone - removed."
    } else {
        Write-Output "  `$zone - not found. Skipping."
    }
}
"@

Write-Host "  Executing on $VmName via run-command..." -ForegroundColor Gray
az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts $script `
    --query "value[].message" -o tsv

Write-Host '  DC01 conditional forwarders removed.' -ForegroundColor Green

# =============================================================================
# [2/4] Cloud: Forwarding Ruleset VNet リンク削除
# =============================================================================
Write-Host ''
Write-Host '[2/4] [Cloud] Forwarding Ruleset VNet リンクを削除中...' -ForegroundColor Yellow

if ($existingRuleset) {
    $linksJson = az dns-resolver vnet-link list --ruleset-name $RulesetName `
        --resource-group $HubResourceGroup -o json 2>$null
    if ($linksJson) {
        $links = $linksJson | ConvertFrom-Json
        foreach ($link in $links) {
            Write-Host "  Removing link: $($link.name)..."
            az dns-resolver vnet-link delete `
                -g $HubResourceGroup --ruleset-name $RulesetName `
                -n $link.name --yes -o none 2>$null
            Write-Host "  $($link.name) removed."
        }
    } else {
        Write-Host '  No VNet links found. Skipping.'
    }
} else {
    Write-Host "  Ruleset '$RulesetName' not found. Skipping."
}

# =============================================================================
# [3/4] Cloud: Forwarding Ruleset 削除 (ルール含む)
# =============================================================================
Write-Host ''
Write-Host "[3/4] [Cloud] Forwarding Ruleset '$RulesetName' を削除中..." -ForegroundColor Yellow

if ($existingRuleset) {
    # Delete forwarding rules first
    $rulesJson = az dns-resolver forwarding-rule list `
        -g $HubResourceGroup --ruleset-name $RulesetName -o json 2>$null
    if ($rulesJson) {
        $rules = $rulesJson | ConvertFrom-Json
        foreach ($rule in $rules) {
            Write-Host "  Removing rule: $($rule.name)..."
            az dns-resolver forwarding-rule delete `
                -g $HubResourceGroup --ruleset-name $RulesetName `
                -n $rule.name --yes -o none 2>$null
        }
    }

    az dns-resolver forwarding-ruleset delete `
        -g $HubResourceGroup -n $RulesetName --yes -o none
    Write-Host "  Ruleset '$RulesetName' removed."
} else {
    Write-Host "  Ruleset '$RulesetName' not found. Skipping."
}

# =============================================================================
# [4/4] Cloud: Private DNS Zone azure.internal 削除
# =============================================================================
Write-Host ''
Write-Host "[4/4] [Cloud] Private DNS Zone '$cloudVmDnsZone' を確認中..." -ForegroundColor Yellow

$cloudVmZoneRemoved = $false
if ($existingZone) {
    Write-Host '  Zone found. Removing...' -ForegroundColor Gray
    # Remove VNet links first
    $dnsLinksJson = az network private-dns link vnet list `
        -g $HubResourceGroup -z $cloudVmDnsZone -o json 2>$null
    if ($dnsLinksJson) {
        $dnsLinks = $dnsLinksJson | ConvertFrom-Json
        foreach ($dl in $dnsLinks) {
            Write-Host "  Removing DNS zone link: $($dl.name)..."
            az network private-dns link vnet delete `
                -g $HubResourceGroup -z $cloudVmDnsZone -n $dl.name --yes -o none 2>$null
        }
    }

    az network private-dns zone delete `
        -g $HubResourceGroup -n $cloudVmDnsZone --yes -o none
    Write-Host "  Zone '$cloudVmDnsZone' removed."
    $cloudVmZoneRemoved = $true
} else {
    Write-Host "  Zone '$cloudVmDnsZone' not found. Skipping."
}

# =============================================================================
# 結果サマリー
# =============================================================================
$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed

Write-Host ''
Write-Host '=== Hybrid DNS Configuration Removed ===' -ForegroundColor Green
Write-Host "  所要時間: $($elapsed.ToString('mm\:ss'))" -ForegroundColor White
Write-Host ''
Write-Host 'Removed:' -ForegroundColor White
Write-Host "  - DC01 ($VmName) conditional forwarders"
if ($existingRuleset) {
    Write-Host "  - Forwarding Ruleset '$RulesetName' + VNet links + rules"
}
if ($cloudVmZoneRemoved) {
    Write-Host "  - Private DNS Zone '$cloudVmDnsZone' + VNet links"
}
Write-Host ''
Write-Host 'Not removed (shared resources):' -ForegroundColor DarkGray
Write-Host '  - Hub DNS Resolver (dnspr-hub)'
Write-Host '  - Hub DNS Resolver inbound/outbound endpoints'
Write-Host ''
Write-Host '再設定するには:' -ForegroundColor White
Write-Host '  .\Setup-HybridDns.ps1'
