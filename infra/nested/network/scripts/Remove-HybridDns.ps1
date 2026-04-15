<#
.SYNOPSIS
    Hybrid DNS 構成を削除する (Setup-HybridDns.ps1 の逆操作)
.DESCRIPTION
    Setup-HybridDns.ps1 で作成した DNS 設定をすべて削除する。
    ローカル PC から Azure CLI + az vm run-command で実行する。

    削除対象:
      [1/7] [On-prem] vm-ad01 条件付きフォワーダー (privatelink.*, azure.internal)
      [2/7] [On-prem] Host 条件付きフォワーダー (contoso.local)
      [3/7] [On-prem] Host DNS クライアントを Azure DNS のみに戻す
      [4/7] [On-prem] Host DNS Server ロール削除 (-KeepDnsServerRole でスキップ)
      [5/7] [Cloud]   Forwarding Rule (contoso.local) 削除 — 他のルールが残れば Ruleset は保持
      [6/7] [Cloud]   残りルールなし → Ruleset + VNet リンク削除 / あり → Ruleset 保持
      [7/7] [Cloud]   Private DNS Zone: azure.internal (存在する場合のみ自動削除)

    ※ Hub DNS Resolver (dnspr-hub) は削除しない (他で共有)

    前提:
      - Azure CLI ログイン済み (az login)
      - ローカル PC から実行
.EXAMPLE
    .\Remove-HybridDns.ps1
.EXAMPLE
    .\Remove-HybridDns.ps1 -KeepDnsServerRole
.EXAMPLE
    .\Remove-HybridDns.ps1 -SkipConfirmation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HostVmName = 'vm-onprem-nested-hv01',
    [string]$DomainName = 'contoso.local',
    [string]$RulesetName = 'frs-hub',
    [switch]$KeepDnsServerRole,
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
# Helper: Run script on Hyper-V host via az vm run-command invoke
# =============================================================================
function Invoke-HostCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Script,
        [string]$StepLabel = ''
    )
    if ($StepLabel) {
        Write-Host "  Host 上で run-command を実行中..." -ForegroundColor Gray
    }
    $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
    try {
        $Script | Set-Content -Path $tmpFile -Encoding UTF8
        $jsonText = az vm run-command invoke `
            --resource-group $OnpremResourceGroup --name $HostVmName `
            --command-id RunPowerShellScript --scripts "@$tmpFile" -o json 2>$null
        if (-not $jsonText) {
            Write-Host "    ERROR: run-command の出力がありません" -ForegroundColor Red
            return ''
        }
        $r = ($jsonText -join '') | ConvertFrom-Json
        $stderr = ($r.value | Where-Object { $_.code -like '*stderr*' }).message
        if ($stderr) { Write-Host "    stderr: $stderr" -ForegroundColor DarkYellow }
        $stdout = ($r.value | Where-Object { $_.code -like '*stdout*' }).message
        return $stdout
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
Write-Host ''
Write-Host '=== Hybrid DNS 構成の削除 ===' -ForegroundColor Cyan
Write-Host ''

# --- 削除対象の確認 ---
Write-Host '削除対象:' -ForegroundColor Yellow
Write-Host "  - vm-ad01 条件付きフォワーダー (privatelink.*, $cloudVmDnsZone)"
Write-Host "  - Host 条件付きフォワーダー ($DomainName)"
Write-Host '  - Host DNS クライアント → Azure DNS のみに復元'
if (-not $KeepDnsServerRole) { Write-Host '  - Host DNS Server ロール' }
Write-Host "  - Forwarding Rule '$(($DomainName -replace '\.', '-'))' ($DomainName)"
Write-Host "  - Private DNS Zone '$cloudVmDnsZone' (存在する場合)"
Write-Host ''
Write-Host '保持するリソース:' -ForegroundColor DarkGray
if ($KeepDnsServerRole) { Write-Host '  - Host DNS Server ロール (-KeepDnsServerRole)' }
Write-Host '  - Hub DNS Resolver (dnspr-hub)'
Write-Host '  - Hub DNS Resolver inbound/outbound エンドポイント'
Write-Host ''

if (-not $SkipConfirmation) {
    $confirm = Read-Host '続行しますか? (y/N)'
    if ($confirm -notmatch '^[yY]') {
        Write-Host 'キャンセルしました。' -ForegroundColor Yellow
        return
    }
}

$totalSteps = 6
if (-not $KeepDnsServerRole) { $totalSteps++ }

# =============================================================================
# [1/N] vm-ad01: Remove conditional forwarders
# =============================================================================
Write-Host "[1/$totalSteps] [On-prem] vm-ad01 の条件付きフォワーダーを削除中..." -ForegroundColor Yellow

$zonesArray = ($privateLinkZones | ForEach-Object { "'$_'" }) -join ','
$allZones = "$zonesArray,'$cloudVmDnsZone'"

Invoke-HostCommand -StepLabel 'vm-ad01 forwarder removal' -Script @"
`$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', `$pw)
`$zones = @($allZones)
Invoke-Command -VMName 'vm-ad01' -Credential `$cred -ScriptBlock {
    param(`$Zones)
    foreach (`$zone in `$Zones) {
        `$existing = Get-DnsServerZone -Name `$zone -ErrorAction SilentlyContinue
        if (`$existing -and `$existing.ZoneType -eq 'Forwarder') {
            Remove-DnsServerZone -Name `$zone -Force
            Write-Output "  `$zone - Removed."
        } else {
            Write-Output "  `$zone - Not found. Skipped."
        }
    }
} -ArgumentList (,`$zones)
"@

# =============================================================================
# [2/N] Host: Remove conditional forwarder
# =============================================================================
Write-Host ''
Write-Host "[2/$totalSteps] [On-prem] Host の条件付きフォワーダー ($DomainName) を削除中..." -ForegroundColor Yellow

Invoke-HostCommand -StepLabel 'Host forwarder removal' -Script @"
`$existing = Get-DnsServerZone -Name '$DomainName' -ErrorAction SilentlyContinue
if (`$existing -and `$existing.ZoneType -eq 'Forwarder') {
    Remove-DnsServerZone -Name '$DomainName' -Force
    Write-Output 'Conditional forwarder removed.'
} else {
    Write-Output 'Conditional forwarder not found. Skipped.'
}
"@

# =============================================================================
# [3/N] Host: Restore DNS client to Azure DNS only
# =============================================================================
Write-Host ''
Write-Host "[3/$totalSteps] [On-prem] Host DNS クライアントを Azure DNS のみに復元中..." -ForegroundColor Yellow

Invoke-HostCommand -StepLabel 'Host DNS client restore' -Script @'
$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
$nicAlias = (Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex).Name
Write-Output "Detected NIC: $nicAlias"
$current = (Get-DnsClientServerAddress -InterfaceAlias $nicAlias -AddressFamily IPv4).ServerAddresses
if ($current -contains '127.0.0.1') {
    Set-DnsClientServerAddress -InterfaceAlias $nicAlias -ServerAddresses @('168.63.129.16')
    $after = (Get-DnsClientServerAddress -InterfaceAlias $nicAlias -AddressFamily IPv4).ServerAddresses
    Write-Output "DNS client restored: $($after -join ',')"
} else {
    Write-Output "DNS client already Azure DNS only: $($current -join ','). Skipped."
}
'@

# =============================================================================
# [4/N] Host: Remove DNS Server role (default, skip with -KeepDnsServerRole)
# =============================================================================
$nextStep = 4
if (-not $KeepDnsServerRole) {
    Write-Host ''
    Write-Host "[$nextStep/$totalSteps] [On-prem] Host の DNS Server ロールを削除中..." -ForegroundColor Yellow

    Invoke-HostCommand -StepLabel 'DNS Server role removal' -Script @'
$dns = Get-WindowsFeature -Name DNS
if ($dns.Installed) {
    Remove-WindowsFeature -Name DNS -IncludeManagementTools
    Write-Output 'DNS Server role removed.'
} else {
    Write-Output 'DNS Server role not installed. Skipped.'
}
'@
    $nextStep++
} else {
    Write-Host ''
    Write-Host "  [スキップ] DNS Server ロールを保持 (-KeepDnsServerRole)" -ForegroundColor DarkGray
}

# =============================================================================
# [N] Cloud: Forwarding Rule 削除 + Ruleset 条件付き削除
# =============================================================================
Write-Host ''
Write-Host "[$nextStep/$totalSteps] [Cloud] Forwarding Rule を削除中..." -ForegroundColor Yellow

$rulesetDeleted = $false
$existingRuleset = az dns-resolver forwarding-ruleset show `
    -g $HubResourceGroup -n $RulesetName --query 'id' -o tsv 2>$null
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

    $nextStep++
    if ($remainingCount -eq 0) {
        Write-Host ''
        Write-Host "[$nextStep/$totalSteps] [Cloud] 残りルールなし — Ruleset と VNet リンクを削除中..." -ForegroundColor Yellow

        # VNet リンク削除
        $linksJson = az dns-resolver vnet-link list --ruleset-name $RulesetName `
            --resource-group $HubResourceGroup -o json 2>$null
        if ($linksJson) {
            $links = $linksJson | ConvertFrom-Json
            foreach ($link in $links) {
                Write-Host "  リンク削除中: $($link.name)..."
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
        Write-Host "[$nextStep/$totalSteps] [Cloud] 他環境のルールが残っています ($remainingCount 件) — Ruleset を保持します。" -ForegroundColor Yellow
        foreach ($r in $remainingRules) {
            Write-Host "  残存ルール: $($r.name) ($($r.domainName) -> $($r.targetDnsServers[0].ipAddress))" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  Ruleset '$RulesetName' が見つかりません。スキップ。"
    $nextStep++
    Write-Host ''
    Write-Host "[$nextStep/$totalSteps] [Cloud] Ruleset '$RulesetName' が見つかりません。スキップ。" -ForegroundColor Yellow
}

# =============================================================================
# [N] Cloud: Remove Private DNS Zone azure.internal (auto-detect)
# =============================================================================
$nextStep++
Write-Host ''
Write-Host "[$nextStep/$totalSteps] [Cloud] Private DNS Zone '$cloudVmDnsZone' を確認中..." -ForegroundColor Yellow

$existingZone = az network private-dns zone show `
    -g $HubResourceGroup -n $cloudVmDnsZone --query 'name' -o tsv 2>$null
if ($existingZone) {
    Write-Host "  ゾーンが見つかりました。削除中..." -ForegroundColor Gray
    # Remove VNet links first
    $dnsLinksJson = az network private-dns link vnet list `
        -g $HubResourceGroup -z $cloudVmDnsZone -o json 2>$null
    if ($dnsLinksJson) {
        $dnsLinks = $dnsLinksJson | ConvertFrom-Json
        foreach ($dl in $dnsLinks) {
            Write-Host "  DNS ゾーンリンク削除中: $($dl.name)..."
            az network private-dns link vnet delete `
                -g $HubResourceGroup -z $cloudVmDnsZone -n $dl.name --yes -o none 2>$null
        }
    }

    az network private-dns zone delete `
        -g $HubResourceGroup -n $cloudVmDnsZone --yes -o none
    Write-Host "  ゾーン '$cloudVmDnsZone' を削除しました。"
    $Script:cloudVmZoneRemoved = $true
} else {
    Write-Host "  ゾーン '$cloudVmDnsZone' が見つかりません。スキップ。"
    $Script:cloudVmZoneRemoved = $false
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ''
Write-Host '=== Hybrid DNS 構成の削除完了 ===' -ForegroundColor Green
Write-Host ''
Write-Host '削除済み:' -ForegroundColor White
Write-Host '  - vm-ad01 条件付きフォワーダー (privatelink.*, azure.internal)'
Write-Host "  - Host 条件付きフォワーダー ($DomainName)"
Write-Host '  - Host DNS クライアント → Azure DNS のみ (168.63.129.16)'
if (-not $KeepDnsServerRole) {
    Write-Host '  - Host DNS Server ロール'
}
if ($rulesetDeleted) {
    Write-Host "  - Forwarding Ruleset '$RulesetName' + VNet リンク + ルール"
} else {
    $ruleName = ($DomainName -replace '\.', '-')
    Write-Host "  - Forwarding Rule '$ruleName' ($DomainName)"
    if ($existingRuleset) {
        Write-Host "  - Ruleset '$RulesetName' は他のルールが残るため保持"
    }
}
if ($Script:cloudVmZoneRemoved) {
    Write-Host "  - Private DNS Zone '$cloudVmDnsZone' + VNet リンク"
}
Write-Host ''
Write-Host '保持するリソース (共有):' -ForegroundColor DarkGray
if ($KeepDnsServerRole) {
    Write-Host '  - Host DNS Server ロール (-KeepDnsServerRole)'
}
Write-Host '  - Hub DNS Resolver (dnspr-hub)'
Write-Host '  - Hub DNS Resolver inbound/outbound エンドポイント'
