<#
.SYNOPSIS
    Hybrid DNS Setup: Cloud (Azure CLI) + On-prem (az vm run-command)
.DESCRIPTION
    Configures bidirectional DNS resolution between on-prem (nested Hyper-V)
    and cloud (Hub DNS Resolver). Runs entirely from the local PC.

    Architecture:
      Cloud -> contoso.local:
        Spoke VM -> Hub DNS Resolver (Outbound) -> Forwarding Ruleset
          -> VPN -> Hyper-V Host (10.1.x.x:53) -> vm-ad01 (192.168.100.10)

      On-prem -> privatelink.*:
        vm-app01 -> vm-ad01 (DNS) -> Conditional Forwarder -> VPN
          -> Hub DNS Resolver (Inbound) -> Private DNS Zone

    Steps:
      [1/8] [Cloud]   DNS Forwarding Ruleset on Hub DNS Resolver
      [2/8] [Cloud]   Forwarding rule: contoso.local -> Hyper-V host IP
      [3/8] [Cloud]   Link ruleset to Hub VNet
      [--]  [Cloud]   Link ruleset to Spoke VNets (optional: -LinkSpokeVnets)
      [4/8] [On-prem] Install DNS Server role on Hyper-V host (run-command)
      [5/8] [On-prem] Host DNS client: 127.0.0.1 + Azure DNS (run-command)
      [6/8] [On-prem] Host conditional forwarder: contoso.local -> vm-ad01 (run-command)
      [7/8] [On-prem] vm-ad01 conditional forwarders: privatelink.* -> Hub DNS Resolver (run-command + PowerShell Direct)
      [8/8] Verification

    Prerequisites:
      - Azure CLI logged in (az login)
      - VPN connection established between onprem-nested and Hub
      - AD DS installed on vm-ad01 (Install-ADDS.ps1)
      - Run from local PC (NOT on Hyper-V host)
.EXAMPLE
    .\Setup-HybridDns.ps1
.EXAMPLE
    .\Setup-HybridDns.ps1 -EnableCloudVmResolution
.EXAMPLE
    .\Setup-HybridDns.ps1 -LinkSpokeVnets
#>

[CmdletBinding()]
param(
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HubDnsResolverName = 'dnspr-hub',
    [string]$HubVnetName = 'vnet-hub',
    [string]$HostVmName = 'vm-onprem-nested-hv01',
    [string]$RulesetName = 'frs-hub',
    [string]$DomainName = 'contoso.local',
    [string]$DcIp = '192.168.100.10',
    [switch]$EnableCloudVmResolution,
    [switch]$LinkSpokeVnets
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
# Discover required information from Azure
# =============================================================================
Write-Host ''
Write-Host '=== Hybrid DNS Setup ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Discovering Azure resources...' -ForegroundColor Yellow

# Hub DNS Resolver Inbound IP
$hubDnsResolverInboundIp = az dns-resolver inbound-endpoint show `
    -g $HubResourceGroup `
    --dns-resolver-name $HubDnsResolverName `
    -n inbound `
    --query 'ipConfigurations[0].privateIpAddress' -o tsv
if (-not $hubDnsResolverInboundIp) {
    throw "Failed to get Hub DNS Resolver inbound IP. Ensure '$HubDnsResolverName' exists in '$HubResourceGroup'."
}
Write-Host "  Hub DNS Resolver Inbound IP: $hubDnsResolverInboundIp"

# Hyper-V host private IP
$hostPrivateIp = az vm list-ip-addresses `
    -g $OnpremResourceGroup -n $HostVmName `
    --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv
if (-not $hostPrivateIp) {
    throw "Failed to get Hyper-V host private IP. Ensure '$HostVmName' exists in '$OnpremResourceGroup'."
}
Write-Host "  Hyper-V Host Private IP:     $hostPrivateIp"

# Hub VNet resource ID
$hubVnetId = az network vnet show `
    -g $HubResourceGroup -n $HubVnetName `
    --query 'id' -o tsv
if (-not $hubVnetId) {
    throw "Failed to get Hub VNet ID. Ensure '$HubVnetName' exists in '$HubResourceGroup'."
}
Write-Host "  Hub VNet:                    $HubVnetName"

# Spoke VNets peered to Hub
$spokeVnets = az network vnet peering list `
    -g $HubResourceGroup --vnet-name $HubVnetName `
    --query '[].{name: name, vnetId: remoteVirtualNetwork.id}' -o json | ConvertFrom-Json
if (-not $spokeVnets) { $spokeVnets = @() }

if ($spokeVnets.Count -gt 0) {
    Write-Host "  Spoke VNets (ピアリング検出): $($spokeVnets.Count) 件"
    foreach ($spoke in $spokeVnets) {
        Write-Host "    - $(($spoke.vnetId -split '/')[-1])"
    }
} else {
    Write-Host '  Spoke VNets: ピアリングなし' -ForegroundColor DarkGray
}

# Location
$location = az network vnet show -g $HubResourceGroup -n $HubVnetName --query 'location' -o tsv
Write-Host "  Location:                    $location"

# Display step plan
$baseSteps = 9
if ($LinkSpokeVnets) { $baseSteps++ }   # [4/N] Spoke VNet リンク
if ($EnableCloudVmResolution) { $baseSteps += 2 }  # [N-1/N] Private DNS Zone + [N/N] vm-ad01 forwarder
$totalSteps = $baseSteps

$step = 0
$stepRuleset     = ++$step  # 1
$stepRule        = ++$step  # 2
$stepHubLink     = ++$step  # 3
if ($LinkSpokeVnets) { $stepSpokeLink = ++$step } else { $stepSpokeLink = 0 }
$stepDnsInstall  = ++$step  # 4 or 5
$stepDnsClient   = ++$step  # 5 or 6
$stepHostFwd     = ++$step  # 6 or 7
$stepAdFwd       = ++$step  # 7 or 8
$stepVerify      = ++$step  # 8 or 9
if ($EnableCloudVmResolution) { $stepCloudZone = ++$step; $stepCloudFwd = ++$step } else { $stepCloudZone = 0; $stepCloudFwd = 0 }

Write-Host ''
Write-Host "Steps ($totalSteps):" -ForegroundColor Cyan
Write-Host "  [$stepRuleset/$totalSteps] [Cloud]   DNS Forwarding Ruleset" -ForegroundColor White
Write-Host "  [$stepRule/$totalSteps] [Cloud]   Forwarding rule: $DomainName -> $hostPrivateIp" -ForegroundColor White
Write-Host "  [$stepHubLink/$totalSteps] [Cloud]   Link ruleset -> Hub VNet" -ForegroundColor White
if ($LinkSpokeVnets) {
    Write-Host "  [$stepSpokeLink/$totalSteps] [Cloud]   Link ruleset -> Spoke VNets ($($spokeVnets.Count))" -ForegroundColor White
} else {
    Write-Host "  [--] [Cloud]   Spoke VNet リンク: スキップ (-LinkSpokeVnets で有効化)" -ForegroundColor DarkGray
}
Write-Host "  [$stepDnsInstall/$totalSteps] [On-prem] Install DNS Server role on host (run-command)" -ForegroundColor White
Write-Host "  [$stepDnsClient/$totalSteps] [On-prem] Host DNS client: 127.0.0.1 + Azure DNS (run-command)" -ForegroundColor White
Write-Host "  [$stepHostFwd/$totalSteps] [On-prem] Host forwarder: $DomainName -> $DcIp (run-command)" -ForegroundColor White
Write-Host "  [$stepAdFwd/$totalSteps] [On-prem] vm-ad01 forwarders: privatelink.* -> $hubDnsResolverInboundIp (run-command)" -ForegroundColor White
Write-Host "  [$stepVerify/$totalSteps] Verification" -ForegroundColor White
if ($EnableCloudVmResolution) {
    Write-Host "  [$stepCloudZone/$totalSteps] [Cloud]   Private DNS Zone: $cloudVmDnsZone" -ForegroundColor White
    Write-Host "  [$stepCloudFwd/$totalSteps] [On-prem] vm-ad01 forwarder: $cloudVmDnsZone -> $hubDnsResolverInboundIp" -ForegroundColor White
}
Write-Host ''

# =============================================================================
# [1/N] DNS Forwarding Ruleset
# =============================================================================
Write-Host "[$stepRuleset/$totalSteps] [Cloud] Creating DNS Forwarding Ruleset '$rulesetName'..." -ForegroundColor Yellow

$outboundEpId = az dns-resolver outbound-endpoint show `
    -g $HubResourceGroup --dns-resolver-name $HubDnsResolverName `
    -n outbound --query 'id' -o tsv

$existingRuleset = az dns-resolver forwarding-ruleset show `
    -g $HubResourceGroup -n $rulesetName --query 'id' -o tsv 2>$null

if ($existingRuleset) {
    Write-Host "  Ruleset '$rulesetName' already exists. Skipping."
} else {
    az dns-resolver forwarding-ruleset create `
        -g $HubResourceGroup -n $rulesetName -l $location `
        --outbound-endpoints "[{id:$outboundEpId}]" -o none
    Write-Host "  Ruleset '$rulesetName' created."
}

# =============================================================================
# [2/N] Forwarding Rule: contoso.local -> Hyper-V host
# =============================================================================
Write-Host ''
Write-Host "[$stepRule/$totalSteps] [Cloud] Forwarding rule: $DomainName -> $hostPrivateIp..." -ForegroundColor Yellow

$ruleName = ($DomainName -replace '\.', '-')
$existingRule = az dns-resolver forwarding-rule show `
    -g $HubResourceGroup --ruleset-name $rulesetName `
    -n $ruleName --query 'domainName' -o tsv 2>$null

if ($existingRule) {
    Write-Host "  Rule '$ruleName' already exists. Updating target..."
    az dns-resolver forwarding-rule update `
        -g $HubResourceGroup --ruleset-name $rulesetName `
        -n $ruleName --target-dns-servers "[{ip-address:$hostPrivateIp,port:53}]" -o none
    Write-Host "  Rule updated."
} else {
    az dns-resolver forwarding-rule create `
        -g $HubResourceGroup --ruleset-name $rulesetName `
        -n $ruleName --domain-name "${DomainName}." `
        --target-dns-servers "[{ip-address:$hostPrivateIp,port:53}]" -o none
    Write-Host "  Rule '$ruleName' created."
}

# =============================================================================
# [3/N] Link ruleset to Hub VNet
# =============================================================================
Write-Host ''
Write-Host "[$stepHubLink/$totalSteps] [Cloud] Linking ruleset to Hub VNet ($HubVnetName)..." -ForegroundColor Yellow

$existingHubLink = az dns-resolver forwarding-ruleset list-by-virtual-network `
    --resource-group $HubResourceGroup --virtual-network-name $HubVnetName `
    --query "[?name=='$rulesetName'].id" -o tsv 2>$null

if ($existingHubLink) {
    Write-Host "  Hub VNet link already exists. Skipping."
} else {
    az dns-resolver vnet-link create `
        -g $HubResourceGroup --ruleset-name $rulesetName `
        -n "link-$HubVnetName" --id $hubVnetId -o none
    Write-Host "  Hub VNet linked."
}

# =============================================================================
# [N] Link ruleset to Spoke VNets (オプション: -LinkSpokeVnets)
# =============================================================================
if ($LinkSpokeVnets) {
    Write-Host ''
    Write-Host "[$stepSpokeLink/$totalSteps] [Cloud] Linking ruleset to Spoke VNets..." -ForegroundColor Yellow

    if ($spokeVnets.Count -eq 0) {
        Write-Host '  ピアリングされた Spoke VNet なし。スキップ。' -ForegroundColor DarkGray
    } else {
        foreach ($spoke in $spokeVnets) {
            $spokeName = ($spoke.vnetId -split '/')[-1]
            $linkName = "link-$spokeName"
            $existingLink = az dns-resolver vnet-link show `
                -g $HubResourceGroup --ruleset-name $rulesetName `
                -n $linkName --query 'id' -o tsv 2>$null
            if ($existingLink) {
                Write-Host "  $spokeName - already linked. Skipping."
            } else {
                az dns-resolver vnet-link create `
                    -g $HubResourceGroup --ruleset-name $rulesetName `
                    -n $linkName --id $spoke.vnetId -o none
                Write-Host "  $spokeName - linked."
            }
        }
    }
} else {
    Write-Host ''
    Write-Host '[--] Spoke VNet リンクスキップ (-LinkSpokeVnets で有効化)' -ForegroundColor DarkGray
}

# =============================================================================
# [5/N] Install DNS Server role on Hyper-V host (run-command)
# =============================================================================
Write-Host ''
Write-Host "[$stepDnsInstall/$totalSteps] [On-prem] Installing DNS Server role on host..." -ForegroundColor Yellow

Invoke-HostCommand -StepLabel 'Install DNS' -Script @'
if ((Get-WindowsFeature DNS).Installed) {
    Write-Output 'DNS Server role already installed. Skipping.'
} else {
    Install-WindowsFeature DNS -IncludeManagementTools | Out-Null
    Write-Output 'DNS Server role installed.'
}
'@

# =============================================================================
# [6/N] Host DNS client: 127.0.0.1 + Azure DNS
# =============================================================================
Write-Host ''
Write-Host "[$stepDnsClient/$totalSteps] [On-prem] Host DNS client: 127.0.0.1 + Azure DNS..." -ForegroundColor Yellow

Invoke-HostCommand -StepLabel 'Host DNS client' -Script @'
$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
$nicAlias = (Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex).Name
Write-Output "Detected NIC: $nicAlias"
$current = (Get-DnsClientServerAddress -InterfaceAlias $nicAlias -AddressFamily IPv4).ServerAddresses
if ($current -contains '127.0.0.1') {
    Write-Output "DNS client already includes 127.0.0.1. Current: $($current -join ',')"
} else {
    Set-DnsClientServerAddress -InterfaceAlias $nicAlias -ServerAddresses @('127.0.0.1','168.63.129.16')
    $after = (Get-DnsClientServerAddress -InterfaceAlias $nicAlias -AddressFamily IPv4).ServerAddresses
    Write-Output "DNS client updated: $($after -join ',')"
}
'@

# =============================================================================
# [7/N] Host conditional forwarder: contoso.local -> vm-ad01 (run-command)
# =============================================================================
Write-Host ''
Write-Host "[$stepHostFwd/$totalSteps] [On-prem] Host forwarder: $DomainName -> $DcIp (vm-ad01)..." -ForegroundColor Yellow

Invoke-HostCommand -StepLabel 'Host DNS forwarder' -Script @"
`$existing = Get-DnsServerZone -Name '$DomainName' -ErrorAction SilentlyContinue
if (`$existing) {
    Set-DnsServerConditionalForwarderZone -Name '$DomainName' -MasterServers '$DcIp'
    Write-Output 'Conditional forwarder updated.'
} else {
    Add-DnsServerConditionalForwarderZone -Name '$DomainName' -MasterServers '$DcIp'
    Write-Output 'Conditional forwarder created.'
}
`$r = Resolve-DnsName -Name '$DomainName' -DnsOnly -ErrorAction SilentlyContinue
if (`$r) { Write-Output 'Verification: $DomainName resolved OK.' }
else { Write-Output 'Warning: $DomainName resolution failed. Check VPN and vm-ad01.' }
"@

# =============================================================================
# [8/N] vm-ad01 conditional forwarders: privatelink.* -> Hub DNS Resolver
#       (run-command + PowerShell Direct)
# =============================================================================
Write-Host ''
Write-Host "[$stepAdFwd/$totalSteps] [On-prem] vm-ad01 forwarders: privatelink.* -> $hubDnsResolverInboundIp..." -ForegroundColor Yellow

$zonesArray = ($privateLinkZones | ForEach-Object { "'$_'" }) -join ','

Invoke-HostCommand -StepLabel 'vm-ad01 DNS forwarders' -Script @"
`$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', `$pw)
`$zones = @($zonesArray)
Invoke-Command -VMName 'vm-ad01' -Credential `$cred -ScriptBlock {
    param(`$ResolverIp, `$Zones)
    foreach (`$zone in `$Zones) {
        `$existing = Get-DnsServerZone -Name `$zone -ErrorAction SilentlyContinue
        if (`$existing) {
            Set-DnsServerConditionalForwarderZone -Name `$zone -MasterServers `$ResolverIp
            Write-Output "  `$zone - updated."
        } else {
            Add-DnsServerConditionalForwarderZone -Name `$zone -MasterServers `$ResolverIp
            Write-Output "  `$zone - created."
        }
    }
} -ArgumentList '$hubDnsResolverInboundIp', `$zones
"@

# =============================================================================
# [9/N] Verification
# =============================================================================
Write-Host ''
Write-Host "[$stepVerify/$totalSteps] Verification" -ForegroundColor Yellow

# Cloud: Forwarding Ruleset rules
Write-Host ''
Write-Host '  [Cloud] Forwarding rules:' -ForegroundColor White
az dns-resolver forwarding-rule list `
    -g $HubResourceGroup --ruleset-name $rulesetName `
    --query '[].{Rule:name, Domain:domainName, Target:targetDnsServers[0].ipAddress}' -o table

# Cloud: VNet Links
Write-Host '  [Cloud] VNet links:' -ForegroundColor White
az dns-resolver vnet-link list `
    -g $HubResourceGroup --ruleset-name $rulesetName `
    --query '[].{Name:name, VNet:virtualNetwork.id}' -o table

# On-prem: Host DNS zones
Write-Host '  [On-prem] Host DNS conditional forwarders:' -ForegroundColor White
Invoke-HostCommand -Script @'
Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' } |
    Select-Object ZoneName, @{N='MasterServers';E={$_.MasterServers -join ','}} |
    ForEach-Object { Write-Output "    $($_.ZoneName) -> $($_.MasterServers)" }
'@

# On-prem: vm-ad01 DNS zones
Write-Host ''
Write-Host '  [On-prem] vm-ad01 DNS conditional forwarders:' -ForegroundColor White
Invoke-HostCommand -Script @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
    Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' } |
        Select-Object ZoneName, @{N='MasterServers';E={$_.MasterServers -join ','}} |
        ForEach-Object { Write-Output "    $($_.ZoneName) -> $($_.MasterServers)" }
}
'@

# Resolution tests
Write-Host ''
Write-Host '  Resolution tests:' -ForegroundColor White

# Test: Host -> contoso.local
$testOut = Invoke-HostCommand -Script @'
$r = Resolve-DnsName -Name 'contoso.local' -DnsOnly -ErrorAction SilentlyContinue
if ($r) { Write-Output "RESULT=OK:$($r[0].IPAddress)" } else { Write-Output 'RESULT=FAIL' }
'@
$testVal = if ($testOut -match 'RESULT=OK:(.+)') { "OK ($($Matches[1]))" } elseif ($testOut -match 'RESULT=FAIL') { 'FAIL' } else { 'ERROR' }
$color = if ($testVal -like 'OK*') { 'Green' } else { 'Red' }
Write-Host "    Host -> contoso.local: $testVal" -ForegroundColor $color

# Test: vm-ad01 -> privatelink.database.windows.net
$testOut2 = Invoke-HostCommand -Script @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
$r = Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
    Resolve-DnsName -Name 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
}
if ($r) { Write-Output 'RESULT=OK' } else { Write-Output 'RESULT=FAIL' }
'@
$testVal2 = if ($testOut2 -match 'RESULT=OK') { 'OK' } elseif ($testOut2 -match 'RESULT=FAIL') { 'FAIL (expected if no SQL PE)' } else { 'ERROR' }
$color2 = if ($testVal2 -eq 'OK') { 'Green' } else { 'Yellow' }
Write-Host "    vm-ad01 -> privatelink.database.windows.net: $testVal2" -ForegroundColor $color2

# Test: vm-app01 -> privatelink.database.windows.net (end-to-end)
$testOut3 = Invoke-HostCommand -Script @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
$r = Invoke-Command -VMName 'vm-app01' -Credential $cred -ScriptBlock {
    Resolve-DnsName -Name 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
}
if ($r) { Write-Output 'RESULT=OK' } else { Write-Output 'RESULT=FAIL' }
'@
$testVal3 = if ($testOut3 -match 'RESULT=OK') { 'OK' } elseif ($testOut3 -match 'RESULT=FAIL') { 'FAIL (expected if no SQL PE)' } else { 'ERROR' }
$color3 = if ($testVal3 -eq 'OK') { 'Green' } else { 'Yellow' }
Write-Host "    vm-app01 -> privatelink.database.windows.net (E2E): $testVal3" -ForegroundColor $color3

# =============================================================================
# [Optional] Cloud VM Resolution (azure.internal)
# =============================================================================
if ($EnableCloudVmResolution) {
    Write-Host ''
    Write-Host "=== Optional: Cloud VM Resolution ($cloudVmDnsZone) ===" -ForegroundColor Cyan

    # [10/11] Private DNS Zone: azure.internal
    Write-Host ''
    Write-Host "[$stepCloudZone/$totalSteps] [Cloud] Private DNS Zone '$cloudVmDnsZone'..." -ForegroundColor Yellow

    $existingZone = az network private-dns zone show `
        -g $HubResourceGroup -n $cloudVmDnsZone --query 'name' -o tsv 2>$null
    if ($existingZone) {
        Write-Host "  Zone '$cloudVmDnsZone' already exists. Skipping."
    } else {
        az network private-dns zone create -g $HubResourceGroup -n $cloudVmDnsZone -o none
        Write-Host "  Zone '$cloudVmDnsZone' created."
    }

    # Link Hub VNet (no auto-registration)
    $existingHubDnsLink = az network private-dns link vnet show `
        -g $HubResourceGroup -z $cloudVmDnsZone -n 'link-vnet-hub' --query 'name' -o tsv 2>$null
    if ($existingHubDnsLink) {
        Write-Host "  Hub VNet link already exists. Skipping."
    } else {
        az network private-dns link vnet create `
            -g $HubResourceGroup -z $cloudVmDnsZone -n 'link-vnet-hub' `
            --virtual-network $hubVnetId --registration-enabled false -o none
        Write-Host "  Hub VNet linked (no auto-registration)."
    }

    # Link Spoke VNets (auto-registration enabled)
    foreach ($spoke in $spokeVnets) {
        $spokeName = ($spoke.vnetId -split '/')[-1]
        $dnsLinkName = "link-$spokeName"
        $existingSpokeDnsLink = az network private-dns link vnet show `
            -g $HubResourceGroup -z $cloudVmDnsZone -n $dnsLinkName --query 'name' -o tsv 2>$null
        if ($existingSpokeDnsLink) {
            Write-Host "  $spokeName - link already exists. Skipping."
        } else {
            az network private-dns link vnet create `
                -g $HubResourceGroup -z $cloudVmDnsZone -n $dnsLinkName `
                --virtual-network $spoke.vnetId --registration-enabled true -o none
            Write-Host "  $spokeName - linked with auto-registration."
        }
    }

    # [11/11] vm-ad01 conditional forwarder: azure.internal -> Hub DNS Resolver
    Write-Host ''
    Write-Host "[$stepCloudFwd/$totalSteps] [On-prem] vm-ad01 forwarder: $cloudVmDnsZone -> $hubDnsResolverInboundIp..." -ForegroundColor Yellow

    Invoke-HostCommand -StepLabel 'azure.internal forwarder' -Script @"
`$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', `$pw)
Invoke-Command -VMName 'vm-ad01' -Credential `$cred -ScriptBlock {
    param(`$ResolverIp, `$Zone)
    `$existing = Get-DnsServerZone -Name `$Zone -ErrorAction SilentlyContinue
    if (`$existing) {
        Set-DnsServerConditionalForwarderZone -Name `$Zone -MasterServers `$ResolverIp
        Write-Output "  `$Zone - updated."
    } else {
        Add-DnsServerConditionalForwarderZone -Name `$Zone -MasterServers `$ResolverIp
        Write-Output "  `$Zone - created."
    }
} -ArgumentList '$hubDnsResolverInboundIp', '$cloudVmDnsZone'
"@
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ''
Write-Host '=== Hybrid DNS Setup Complete ===' -ForegroundColor Green
Write-Host ''
Write-Host 'DNS flow:' -ForegroundColor White
Write-Host '  Cloud -> contoso.local:'
Write-Host "    Spoke VM -> Hub DNS Resolver (Outbound) -> Ruleset ($rulesetName)"
Write-Host "      -> VPN -> Host ($HostVmName, $hostPrivateIp:53) -> vm-ad01 ($DcIp)"
Write-Host '  On-prem -> privatelink.*:'
Write-Host "    vm-ad01 -> VPN -> Hub DNS Resolver (Inbound, $hubDnsResolverInboundIp) -> Private DNS Zone"
if ($EnableCloudVmResolution) {
    Write-Host "  On-prem -> ${cloudVmDnsZone}:"
    Write-Host "    vm-ad01 -> VPN -> Hub DNS Resolver (Inbound, $hubDnsResolverInboundIp) -> Private DNS Zone ($cloudVmDnsZone)"
}
