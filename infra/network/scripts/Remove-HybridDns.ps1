<#
.SYNOPSIS
    Hybrid DNS 構成を削除する (Setup-HybridDns.ps1 の逆操作)
.DESCRIPTION
    Setup-HybridDns.ps1 で作成した DNS 設定をすべて削除する。
    ローカル PC から Azure CLI + az vm run-command で実行する。

    削除対象:
      [1/4] [On-prem] DC01 条件付きフォワーダー (privatelink.database.windows.net, azure.internal)
      [2/4] [Cloud]   Forwarding Rule (lab.local) を削除 — 他のルールが残れば Ruleset は保持
      [3/4] [Cloud]   残りルールなし → Ruleset + VNet リンク削除 / あり → Ruleset 保持
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
    [string]$DomainName = 'lab.local',
    [string]$RulesetName = 'frs-hub',
    [switch]$SkipConfirmation
)

$ErrorActionPreference = 'Stop'

$privateLinkZones = @(
    'privatelink.database.windows.net'
    # 'privatelink.blob.core.windows.net'     # Spoke3/4 展開時に有効化
    # 'privatelink.vaultcore.azure.net'        # Spoke3/4 展開時に有効化
    # 'privatelink.azurewebsites.net'          # Spoke4 展開時に有効化
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
$tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
try {
    $script | Set-Content -Path $tmpFile -Encoding UTF8
    $jsonText = az vm run-command invoke `
        --resource-group $OnpremResourceGroup `
        --name $VmName `
        --command-id RunPowerShellScript `
        --scripts "@$tmpFile" -o json 2>$null
    if ($jsonText) {
        $r = ($jsonText -join '') | ConvertFrom-Json
        $stderr = ($r.value | Where-Object { $_.code -like '*stderr*' }).message
        if ($stderr) { Write-Host "    stderr: $stderr" -ForegroundColor DarkYellow }
        $stdout = ($r.value | Where-Object { $_.code -like '*stdout*' }).message
        if ($stdout) { Write-Host $stdout }
    } else {
        Write-Host '    ERROR: run-command の出力がありません' -ForegroundColor Red
    }
} finally {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

Write-Host '  DC01 conditional forwarders removed.' -ForegroundColor Green

# =============================================================================
# [2/4] Cloud: Forwarding Rule 削除 + Ruleset 条件付き削除
# =============================================================================
Write-Host ''
Write-Host '[2/4] [Cloud] Forwarding Rule を削除中...' -ForegroundColor Yellow

$rulesetDeleted = $false
if ($existingRuleset) {
    # 自分の Forwarding Rule のみ削除
    $ruleName = ($DomainName -replace '\.', '-')
    $existingRule = az dns-resolver forwarding-rule show `
        -g $HubResourceGroup --ruleset-name $RulesetName `
        -n $ruleName --query 'name' -o tsv 2>$null
    if ($existingRule) {
        az dns-resolver forwarding-rule delete `
            -g $HubResourceGroup --ruleset-name $RulesetName `
            -n $ruleName --yes -o none
        Write-Host "  ルール '$ruleName' を削除しました。"
    } else {
        Write-Host "  ルール '$ruleName' が見つかりません。スキップ。"
    }

    # 残りルール数を確認
    $remainingRulesJson = az dns-resolver forwarding-rule list `
        -g $HubResourceGroup --ruleset-name $RulesetName -o json 2>$null
    $remainingRules = if ($remainingRulesJson) { ($remainingRulesJson | ConvertFrom-Json) } else { @() }
    $remainingCount = if ($remainingRules) { $remainingRules.Count } else { 0 }

    if ($remainingCount -eq 0) {
        Write-Host ''
        Write-Host '[3/4] [Cloud] 残りルールなし — Ruleset と VNet リンクを削除中...' -ForegroundColor Yellow

        # VNet リンク削除
        $linksJson = az dns-resolver vnet-link list --ruleset-name $RulesetName `
            --resource-group $HubResourceGroup -o json 2>$null
        if ($linksJson) {
            $links = $linksJson | ConvertFrom-Json
            foreach ($link in $links) {
                Write-Host "  Removing link: $($link.name)..."
                az dns-resolver vnet-link delete `
                    -g $HubResourceGroup --ruleset-name $RulesetName `
                    -n $link.name --yes -o none 2>$null
            }
        }

        # Ruleset 削除
        az dns-resolver forwarding-ruleset delete `
            -g $HubResourceGroup -n $RulesetName --yes -o none
        Write-Host "  Ruleset '$RulesetName' を削除しました。"
        $rulesetDeleted = $true
    } else {
        Write-Host ''
        Write-Host "[3/4] [Cloud] 他環境のルールが残っています ($remainingCount 件) — Ruleset を保持します。" -ForegroundColor Yellow
        foreach ($r in $remainingRules) {
            Write-Host "  残存ルール: $($r.name) ($($r.domainName) -> $($r.targetDnsServers[0].ipAddress))" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  Ruleset '$RulesetName' が見つかりません。スキップ。"
    Write-Host ''
    Write-Host "[3/4] [Cloud] Ruleset '$RulesetName' が見つかりません。スキップ。" -ForegroundColor Yellow
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
Write-Host ''
Write-Host '=== Hybrid DNS Configuration Removed ===' -ForegroundColor Green
Write-Host ''
Write-Host 'Removed:' -ForegroundColor White
Write-Host "  - DC01 ($VmName) conditional forwarders"
if ($rulesetDeleted) {
    Write-Host "  - Forwarding Ruleset '$RulesetName' + VNet links + rules"
} else {
    $ruleName = ($DomainName -replace '\.', '-')
    Write-Host "  - Forwarding Rule '$ruleName' ($DomainName)"
    if ($existingRuleset) {
        Write-Host "  - Ruleset '$RulesetName' は他のルールが残るため保持"
    }
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
