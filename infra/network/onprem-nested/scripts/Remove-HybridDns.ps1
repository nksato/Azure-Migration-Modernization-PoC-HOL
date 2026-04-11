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
      [5/7] [Cloud]   Forwarding Ruleset VNet リンク (Hub + Spoke)
      [6/7] [Cloud]   DNS Forwarding Ruleset (frs-onprem) — ルール含む
      [7/7] [Cloud]   Private DNS Zone: azure.internal (存在する場合のみ自動削除)

    ※ Hub DNS Resolver (dnspr-hub) は削除しない (他で共有)

    前提:
      - Azure CLI ログイン済み (az login)
      - ローカル PC から実行
.EXAMPLE
    .\Remove-HybridDns.ps1
.EXAMPLE
    .\Remove-HybridDns.ps1 -KeepDnsServerRole
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HostVmName = 'vm-onprem-nested-hv01',
    [string]$DomainName = 'contoso.local',
    [string]$RulesetName = 'frs-onprem',
    [switch]$KeepDnsServerRole
)

$ErrorActionPreference = 'Stop'

$privateLinkZones = @(
    'privatelink.database.windows.net'
    'privatelink.blob.core.windows.net'
    'privatelink.vaultcore.azure.net'
    'privatelink.azurewebsites.net'
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
        Write-Host "  Executing on host via run-command..." -ForegroundColor Gray
    }
    $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
    try {
        $Script | Set-Content -Path $tmpFile -Encoding UTF8
        $jsonText = az vm run-command invoke `
            --resource-group $OnpremResourceGroup --name $HostVmName `
            --command-id RunPowerShellScript --scripts "@$tmpFile" -o json 2>$null
        if (-not $jsonText) {
            Write-Host "    ERROR: run-command returned no output" -ForegroundColor Red
            return ''
        }
        $r = ($jsonText -join '') | ConvertFrom-Json
        $stderr = ($r.value | Where-Object { $_.code -like '*stderr*' }).message
        if ($stderr) { Write-Host "    stderr: $stderr" -ForegroundColor DarkYellow }
        $stdout = ($r.value | Where-Object { $_.code -like '*stdout*' }).message
        if ($stdout) { Write-Host $stdout }
        return $stdout
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
Write-Host ''
Write-Host '=== Remove Hybrid DNS Configuration ===' -ForegroundColor Cyan
Write-Host ''

$totalSteps = 6
if (-not $KeepDnsServerRole) { $totalSteps++ }

# =============================================================================
# [1/N] vm-ad01: Remove conditional forwarders
# =============================================================================
Write-Host "[1/$totalSteps] [On-prem] Removing vm-ad01 conditional forwarders..." -ForegroundColor Yellow

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
            Write-Output "  `$zone - removed."
        } else {
            Write-Output "  `$zone - not found. Skipping."
        }
    }
} -ArgumentList (,`$zones)
"@

# =============================================================================
# [2/N] Host: Remove conditional forwarder
# =============================================================================
Write-Host ''
Write-Host "[2/$totalSteps] [On-prem] Removing Host conditional forwarder ($DomainName)..." -ForegroundColor Yellow

Invoke-HostCommand -StepLabel 'Host forwarder removal' -Script @"
`$existing = Get-DnsServerZone -Name '$DomainName' -ErrorAction SilentlyContinue
if (`$existing -and `$existing.ZoneType -eq 'Forwarder') {
    Remove-DnsServerZone -Name '$DomainName' -Force
    Write-Output 'Conditional forwarder removed.'
} else {
    Write-Output 'Conditional forwarder not found. Skipping.'
}
"@

# =============================================================================
# [3/N] Host: Restore DNS client to Azure DNS only
# =============================================================================
Write-Host ''
Write-Host "[3/$totalSteps] [On-prem] Restoring Host DNS client to Azure DNS only..." -ForegroundColor Yellow

Invoke-HostCommand -StepLabel 'Host DNS client restore' -Script @'
$current = (Get-DnsClientServerAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4).ServerAddresses
if ($current -contains '127.0.0.1') {
    Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses @('168.63.129.16')
    $after = (Get-DnsClientServerAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4).ServerAddresses
    Write-Output "DNS client restored: $($after -join ',')"
} else {
    Write-Output "DNS client already Azure DNS only: $($current -join ','). Skipping."
}
'@

# =============================================================================
# [4/N] Host: Remove DNS Server role (default, skip with -KeepDnsServerRole)
# =============================================================================
$nextStep = 4
if (-not $KeepDnsServerRole) {
    Write-Host ''
    Write-Host "[$nextStep/$totalSteps] [On-prem] Removing DNS Server role from host..." -ForegroundColor Yellow

    Invoke-HostCommand -StepLabel 'DNS Server role removal' -Script @'
$dns = Get-WindowsFeature -Name DNS
if ($dns.Installed) {
    Remove-WindowsFeature -Name DNS -IncludeManagementTools
    Write-Output 'DNS Server role removed.'
} else {
    Write-Output 'DNS Server role not installed. Skipping.'
}
'@
    $nextStep++
} else {
    Write-Host ''
    Write-Host "  [Skipped] DNS Server role kept (-KeepDnsServerRole)" -ForegroundColor DarkGray
}

# =============================================================================
# [N] Cloud: Remove Forwarding Ruleset VNet links + Ruleset
# =============================================================================
Write-Host ''
Write-Host "[$nextStep/$totalSteps] [Cloud] Removing Forwarding Ruleset VNet links..." -ForegroundColor Yellow

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

# =============================================================================
# [N] Cloud: Remove Forwarding Ruleset (includes rules)
# =============================================================================
$nextStep++
Write-Host ''
Write-Host "[$nextStep/$totalSteps] [Cloud] Removing Forwarding Ruleset '$RulesetName'..." -ForegroundColor Yellow

$existingRuleset = az dns-resolver forwarding-ruleset show `
    -g $HubResourceGroup -n $RulesetName --query 'id' -o tsv 2>$null
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
# [N] Cloud: Remove Private DNS Zone azure.internal (auto-detect)
# =============================================================================
$nextStep++
Write-Host ''
Write-Host "[$nextStep/$totalSteps] [Cloud] Checking Private DNS Zone '$cloudVmDnsZone'..." -ForegroundColor Yellow

$existingZone = az network private-dns zone show `
    -g $HubResourceGroup -n $cloudVmDnsZone --query 'name' -o tsv 2>$null
if ($existingZone) {
    Write-Host "  Zone found. Removing..." -ForegroundColor Gray
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
    $Script:cloudVmZoneRemoved = $true
} else {
    Write-Host "  Zone '$cloudVmDnsZone' not found. Skipping."
    $Script:cloudVmZoneRemoved = $false
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ''
Write-Host '=== Hybrid DNS Configuration Removed ===' -ForegroundColor Green
Write-Host ''
Write-Host 'Removed:' -ForegroundColor White
Write-Host '  - vm-ad01 conditional forwarders (privatelink.*, azure.internal)'
Write-Host "  - Host conditional forwarder ($DomainName)"
Write-Host '  - Host DNS client -> Azure DNS only (168.63.129.16)'
if (-not $KeepDnsServerRole) {
    Write-Host '  - Host DNS Server role'
}
Write-Host "  - Forwarding Ruleset '$RulesetName' + VNet links + rules"
if ($Script:cloudVmZoneRemoved) {
    Write-Host "  - Private DNS Zone '$cloudVmDnsZone' + VNet links"
}
Write-Host ''
Write-Host 'Not removed (shared resources):' -ForegroundColor DarkGray
if ($KeepDnsServerRole) {
    Write-Host '  - DNS Server role on host (-KeepDnsServerRole)'
}
Write-Host '  - Hub DNS Resolver (dnspr-hub)'
Write-Host '  - Hub DNS Resolver inbound/outbound endpoints'
