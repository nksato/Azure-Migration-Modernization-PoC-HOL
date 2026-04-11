# =============================================================================
# Setup-HybridDns.ps1
# Hybrid DNS Setup: Cloud (Azure CLI) + On-prem (PowerShell Direct)
#
# This script configures bidirectional DNS resolution between on-prem and cloud:
#
# Architecture:
#   Cloud -> contoso.local:
#     Spoke VM -> Hub DNS Resolver (Outbound) -> Forwarding Ruleset
#       -> VPN -> Hyper-V Host (10.1.1.x:53) -> vm-ad01 (192.168.100.10)
#
#   On-prem -> privatelink.*:
#     vm-app01 -> vm-ad01 (DNS) -> Conditional Forwarder -> VPN
#       -> Hub DNS Resolver (Inbound) -> Private DNS Zone
#
# Steps:
#   [1/8] [Cloud]   DNS Forwarding Ruleset on Hub DNS Resolver
#   [2/8] [Cloud]   Forwarding rule: contoso.local -> Hyper-V host
#   [3/8] [Cloud]   Link ruleset to Hub VNet
#   [4/8] [Cloud]   Link ruleset to Spoke VNets (peered to Hub)
#   [5/8] [On-prem] Install DNS Server role on Hyper-V host
#   [6/8] [On-prem] Host conditional forwarder: contoso.local -> vm-ad01
#   [7/8] [On-prem] vm-ad01 conditional forwarders: privatelink.* -> Hub DNS Resolver
#   [8/8] Verification
#
#   Optional:
#     -EnableCloudVmResolution: Create azure.internal Private DNS Zone + forwarder
#
# Prerequisites:
#   - Azure CLI logged in (az login)
#   - VPN connection established (vpn-deploy.bicep)
#   - AD DS installed on vm-ad01 (Install-ADDS.ps1)
#   - Run on Hyper-V host via Bastion
#
# Usage:
#   .\Setup-HybridDns.ps1
#   .\Setup-HybridDns.ps1 -EnableCloudVmResolution
#   .\Setup-HybridDns.ps1 -HubResourceGroup rg-hub -OnpremResourceGroup rg-onprem-nested
# =============================================================================

#Requires -RunAsAdministrator

param(
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HubDnsResolverName = 'dnspr-hub',
    [string]$HubVnetName = 'vnet-hub',
    [string]$HypervHostVmName = 'vm-onprem-nested-hv01',
    [string]$DomainName = 'contoso.local',
    [string]$DcVmName = 'vm-ad01',
    [string]$DcIp = '192.168.100.10',
    [string]$DomainNetBios = 'CONTOSO',
    [string]$DomainAdminPassword = 'P@ssW0rd1234!',
    [switch]$EnableCloudVmResolution
)

$ErrorActionPreference = 'Stop'

$domainPassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
$domainCred = New-Object System.Management.Automation.PSCredential("$DomainNetBios\Administrator", $domainPassword)

$privateLinkZones = @(
    'privatelink.database.windows.net'
    'privatelink.blob.core.windows.net'
    'privatelink.vaultcore.azure.net'
    'privatelink.azurewebsites.net'
)

$cloudVmDnsZone = 'azure.internal'
$rulesetName = 'frs-onprem'

# =============================================================================
# Discover required information from Azure
# =============================================================================
Write-Host '=== Hybrid DNS Setup ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Discovering Azure resources...' -ForegroundColor Yellow

# Get Hub DNS Resolver Inbound IP
$hubDnsResolverInboundIp = az dns-resolver inbound-endpoint show `
    -g $HubResourceGroup `
    --dns-resolver-name $HubDnsResolverName `
    -n inbound `
    --query 'ipConfigurations[0].privateIpAddress' -o tsv
if (-not $hubDnsResolverInboundIp) {
    throw "Failed to get Hub DNS Resolver inbound IP. Ensure '$HubDnsResolverName' exists in '$HubResourceGroup'."
}
Write-Host "  Hub DNS Resolver Inbound IP: $hubDnsResolverInboundIp"

# Get Hyper-V host private IP
$hostPrivateIp = az vm list-ip-addresses `
    -g $OnpremResourceGroup `
    -n $HypervHostVmName `
    --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv
if (-not $hostPrivateIp) {
    throw "Failed to get Hyper-V host private IP. Ensure '$HypervHostVmName' exists in '$OnpremResourceGroup'."
}
Write-Host "  Hyper-V Host Private IP:     $hostPrivateIp"

# Get Hub VNet resource ID
$hubVnetId = az network vnet show `
    -g $HubResourceGroup `
    -n $HubVnetName `
    --query 'id' -o tsv
if (-not $hubVnetId) {
    throw "Failed to get Hub VNet ID. Ensure '$HubVnetName' exists in '$HubResourceGroup'."
}
Write-Host "  Hub VNet:                    $HubVnetName"

# Discover Spoke VNets peered to Hub
$spokeVnets = az network vnet peering list `
    -g $HubResourceGroup `
    --vnet-name $HubVnetName `
    --query '[].{name: name, vnetId: remoteVirtualNetwork.id}' -o json | ConvertFrom-Json
if ($spokeVnets.Count -gt 0) {
    Write-Host "  Spoke VNets (peered):        $($spokeVnets.Count) found"
    foreach ($spoke in $spokeVnets) {
        $spokeName = ($spoke.vnetId -split '/')[-1]
        Write-Host "    - $spokeName"
    }
} else {
    Write-Host '  Spoke VNets (peered):        None found' -ForegroundColor DarkGray
}

# Get Location from Hub VNet
$location = az network vnet show -g $HubResourceGroup -n $HubVnetName --query 'location' -o tsv
Write-Host "  Location:                    $location"
Write-Host ''

# Display step plan
$totalSteps = if ($EnableCloudVmResolution) { 10 } else { 8 }
Write-Host "Steps ($totalSteps):" -ForegroundColor Cyan
Write-Host "  [1/$totalSteps] [Cloud]   DNS Forwarding Ruleset" -ForegroundColor Cyan
Write-Host "  [2/$totalSteps] [Cloud]   Forwarding rule: $DomainName -> $hostPrivateIp" -ForegroundColor Cyan
Write-Host "  [3/$totalSteps] [Cloud]   Link ruleset -> Hub VNet ($HubVnetName)" -ForegroundColor Cyan
Write-Host "  [4/$totalSteps] [Cloud]   Link ruleset -> Spoke VNets ($($spokeVnets.Count) VNets)" -ForegroundColor Cyan
Write-Host "  [5/$totalSteps] [On-prem] Install DNS Server role on host" -ForegroundColor Cyan
Write-Host "  [6/$totalSteps] [On-prem] Host forwarder: $DomainName -> $DcIp ($DcVmName)" -ForegroundColor Cyan
Write-Host "  [7/$totalSteps] [On-prem] $DcVmName forwarders: privatelink.* -> $hubDnsResolverInboundIp" -ForegroundColor Cyan
Write-Host "  [8/$totalSteps] Verification" -ForegroundColor Cyan
if ($EnableCloudVmResolution) {
    Write-Host "  [9/$totalSteps] [Cloud]   Private DNS Zone: $cloudVmDnsZone" -ForegroundColor Cyan
    Write-Host "  [10/$totalSteps] [On-prem] $DcVmName forwarder: $cloudVmDnsZone -> $hubDnsResolverInboundIp" -ForegroundColor Cyan
}
Write-Host ''

# =============================================================================
# [1] DNS Forwarding Ruleset
# =============================================================================
Write-Host "[1/$totalSteps] [Cloud] Creating DNS Forwarding Ruleset '$rulesetName'..." -ForegroundColor Yellow

$outboundEpId = az dns-resolver outbound-endpoint show `
    -g $HubResourceGroup `
    --dns-resolver-name $HubDnsResolverName `
    -n outbound `
    --query 'id' -o tsv

$existingRuleset = az dns-resolver forwarding-ruleset show `
    -g $HubResourceGroup `
    -n $rulesetName `
    --query 'id' -o tsv 2>$null

if ($existingRuleset) {
    Write-Host "  Forwarding ruleset '$rulesetName' already exists. Skipping creation."
} else {
    az dns-resolver forwarding-ruleset create `
        -g $HubResourceGroup `
        -n $rulesetName `
        -l $location `
        --outbound-endpoints "[{id:$outboundEpId}]" `
        -o none
    Write-Host "  Forwarding ruleset '$rulesetName' created."
}

# =============================================================================
# [2] Forwarding Rule: contoso.local -> Hyper-V host
# =============================================================================
Write-Host ''
Write-Host "[2/$totalSteps] [Cloud] Creating forwarding rule: $DomainName -> $hostPrivateIp..." -ForegroundColor Yellow

$ruleName = ($DomainName -replace '\.', '-')  # contoso-local
$existingRule = az dns-resolver forwarding-rule show `
    -g $HubResourceGroup `
    --ruleset-name $rulesetName `
    -n $ruleName `
    --query 'domainName' -o tsv 2>$null

if ($existingRule) {
    Write-Host "  Rule '$ruleName' already exists. Updating target DNS servers..."
    az dns-resolver forwarding-rule update `
        -g $HubResourceGroup `
        --ruleset-name $rulesetName `
        -n $ruleName `
        --target-dns-servers "[{ip-address:$hostPrivateIp,port:53}]" `
        -o none
    Write-Host "  Rule '$ruleName' updated."
} else {
    az dns-resolver forwarding-rule create `
        -g $HubResourceGroup `
        --ruleset-name $rulesetName `
        -n $ruleName `
        --domain-name "${DomainName}." `
        --target-dns-servers "[{ip-address:$hostPrivateIp,port:53}]" `
        -o none
    Write-Host "  Rule '$ruleName' created."
}

# =============================================================================
# [3] Link ruleset to Hub VNet
# =============================================================================
Write-Host ''
Write-Host "[3/$totalSteps] [Cloud] Linking ruleset to Hub VNet ($HubVnetName)..." -ForegroundColor Yellow

$existingHubLink = az dns-resolver forwarding-ruleset list-by-virtual-network `
    --resource-group $HubResourceGroup `
    --virtual-network-name $HubVnetName `
    --query "[?name=='$rulesetName'].id" -o tsv 2>$null

if ($existingHubLink) {
    Write-Host "  Hub VNet link already exists. Skipping."
} else {
    az dns-resolver vnet-link create `
        -g $HubResourceGroup `
        --ruleset-name $rulesetName `
        -n 'link-hub-vnet' `
        --id $hubVnetId `
        -o none
    Write-Host "  Hub VNet linked to ruleset."
}

# =============================================================================
# [4] Link ruleset to Spoke VNets
# =============================================================================
Write-Host ''
Write-Host "[4/$totalSteps] [Cloud] Linking ruleset to Spoke VNets..." -ForegroundColor Yellow

if ($spokeVnets.Count -eq 0) {
    Write-Host '  No Spoke VNets peered to Hub. Skipping.' -ForegroundColor DarkGray
} else {
    foreach ($spoke in $spokeVnets) {
        $spokeName = ($spoke.vnetId -split '/')[-1]
        $linkName = "link-$spokeName"

        # Check if link already exists
        $existingLink = az dns-resolver vnet-link show `
            -g $HubResourceGroup `
            --ruleset-name $rulesetName `
            -n $linkName `
            --query 'id' -o tsv 2>$null

        if ($existingLink) {
            Write-Host "  $spokeName - link already exists. Skipping."
        } else {
            az dns-resolver vnet-link create `
                -g $HubResourceGroup `
                --ruleset-name $rulesetName `
                -n $linkName `
                --id $spoke.vnetId `
                -o none
            Write-Host "  $spokeName - linked to ruleset."
        }
    }
}

# =============================================================================
# [5] Install DNS Server role on Hyper-V host
# =============================================================================
Write-Host ''
Write-Host "[5/$totalSteps] [On-prem] Installing DNS Server role on host..." -ForegroundColor Yellow

if ((Get-WindowsFeature DNS).Installed) {
    Write-Host '  DNS Server role already installed. Skipping.'
} else {
    Install-WindowsFeature DNS -IncludeManagementTools
    Write-Host '  DNS Server role installed.'
}

# =============================================================================
# [6] Host conditional forwarder: contoso.local -> vm-ad01
# =============================================================================
Write-Host ''
Write-Host "[6/$totalSteps] [On-prem] Configuring host forwarder: $DomainName -> $DcIp ($DcVmName)..." -ForegroundColor Yellow

$existingForwarder = Get-DnsServerZone -Name $DomainName -ErrorAction SilentlyContinue
if ($existingForwarder) {
    Write-Host "  Conditional forwarder for $DomainName already exists. Updating..."
    Set-DnsServerConditionalForwarderZone -Name $DomainName -MasterServers $DcIp
} else {
    Add-DnsServerConditionalForwarderZone -Name $DomainName -MasterServers $DcIp
    Write-Host '  Conditional forwarder created.'
}

# Quick verification
$resolved = Resolve-DnsName -Name $DomainName -DnsOnly -ErrorAction SilentlyContinue
if ($resolved) {
    Write-Host "  Verification: $DomainName resolved successfully."
} else {
    Write-Host "  Warning: $DomainName resolution failed. Check VPN and $DcVmName status." -ForegroundColor DarkYellow
}

# =============================================================================
# [7] vm-ad01 conditional forwarders: privatelink.* -> Hub DNS Resolver
# =============================================================================
Write-Host ''
Write-Host "[7/$totalSteps] [On-prem] Configuring $DcVmName forwarders: privatelink.* -> $hubDnsResolverInboundIp..." -ForegroundColor Yellow

Invoke-Command -VMName $DcVmName -Credential $domainCred -ScriptBlock {
    param($ResolverIp, $Zones)

    foreach ($zone in $Zones) {
        $existing = Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $zone - already exists. Updating..."
            Set-DnsServerConditionalForwarderZone -Name $zone -MasterServers $ResolverIp
        } else {
            Add-DnsServerConditionalForwarderZone -Name $zone -MasterServers $ResolverIp
            Write-Host "  $zone - created."
        }
    }
} -ArgumentList $hubDnsResolverInboundIp, $privateLinkZones

# =============================================================================
# [8] Verification
# =============================================================================
Write-Host ''
Write-Host "[8/$totalSteps] Verification" -ForegroundColor Yellow
Write-Host ''

# --- Cloud resources ---
Write-Host '[Cloud] Forwarding Ruleset:' -ForegroundColor White
az dns-resolver forwarding-rule list `
    -g $HubResourceGroup `
    --ruleset-name $rulesetName `
    --query '[].{Rule:name, Domain:domainName, Target:targetDnsServers[0].ipAddress}' `
    -o table

Write-Host '[Cloud] VNet Links:' -ForegroundColor White
az dns-resolver vnet-link list `
    -g $HubResourceGroup `
    --ruleset-name $rulesetName `
    --query '[].{Name:name, VNet:virtualNetwork.id}' `
    -o table

# --- Host DNS Server zones ---
Write-Host '[On-prem] Host DNS - Conditional Forwarders:' -ForegroundColor White
Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' } |
    Format-Table ZoneName, ZoneType, MasterServers -AutoSize

# --- vm-ad01 DNS Server zones ---
Write-Host "[On-prem] $DcVmName DNS - Conditional Forwarders:" -ForegroundColor White
Invoke-Command -VMName $DcVmName -Credential $domainCred -ScriptBlock {
    Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' } |
        Format-Table ZoneName, ZoneType, MasterServers -AutoSize
}

# --- Resolution tests ---
Write-Host 'Resolution Tests:' -ForegroundColor White
$testResults = @()

# Test: host -> contoso.local
$r1 = Resolve-DnsName -Name $DomainName -DnsOnly -ErrorAction SilentlyContinue
$testResults += [PSCustomObject]@{
    From   = 'Host'
    Query  = $DomainName
    Result = if ($r1) { 'OK' } else { 'FAIL' }
}

# Test: vm-ad01 -> privatelink.database.windows.net
$r2 = Invoke-Command -VMName $DcVmName -Credential $domainCred -ScriptBlock {
    Resolve-DnsName -Name 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
} -ErrorAction SilentlyContinue
$testResults += [PSCustomObject]@{
    From   = $DcVmName
    Query  = 'privatelink.database.windows.net'
    Result = if ($r2) { 'OK' } else { 'FAIL (expected if no SQL PE)' }
}

# Test: vm-app01 -> privatelink.database.windows.net (end-to-end)
$r3 = Invoke-Command -VMName 'vm-app01' -Credential $domainCred -ScriptBlock {
    Resolve-DnsName -Name 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
} -ErrorAction SilentlyContinue
$testResults += [PSCustomObject]@{
    From   = 'vm-app01'
    Query  = 'privatelink.database.windows.net'
    Result = if ($r3) { 'OK' } else { 'FAIL (expected if no SQL PE)' }
}

$testResults | Format-Table From, Query, Result -AutoSize

# =============================================================================
# [Optional] Cloud VM Resolution (azure.internal)
# =============================================================================
if ($EnableCloudVmResolution) {
    Write-Host ''
    Write-Host "=== Optional: Cloud VM Resolution ($cloudVmDnsZone) ===" -ForegroundColor Cyan

    # [9] Create Private DNS Zone: azure.internal
    Write-Host ''
    Write-Host "[9/$totalSteps] [Cloud] Creating Private DNS Zone '$cloudVmDnsZone'..." -ForegroundColor Yellow

    $existingZone = az network private-dns zone show `
        -g $HubResourceGroup `
        -n $cloudVmDnsZone `
        --query 'name' -o tsv 2>$null

    if ($existingZone) {
        Write-Host "  Private DNS Zone '$cloudVmDnsZone' already exists. Skipping."
    } else {
        az network private-dns zone create `
            -g $HubResourceGroup `
            -n $cloudVmDnsZone `
            -o none
        Write-Host "  Private DNS Zone '$cloudVmDnsZone' created."
    }

    # Link Hub VNet (no auto-registration)
    $existingHubDnsLink = az network private-dns link vnet show `
        -g $HubResourceGroup `
        -z $cloudVmDnsZone `
        -n 'link-vnet-hub' `
        --query 'name' -o tsv 2>$null

    if ($existingHubDnsLink) {
        Write-Host "  Hub VNet link already exists. Skipping."
    } else {
        az network private-dns link vnet create `
            -g $HubResourceGroup `
            -z $cloudVmDnsZone `
            -n 'link-vnet-hub' `
            --virtual-network $hubVnetId `
            --registration-enabled false `
            -o none
        Write-Host "  Hub VNet linked (no auto-registration)."
    }

    # Link Spoke VNets (auto-registration enabled)
    foreach ($spoke in $spokeVnets) {
        $spokeName = ($spoke.vnetId -split '/')[-1]
        $dnsLinkName = "link-$spokeName"

        $existingSpokeDnsLink = az network private-dns link vnet show `
            -g $HubResourceGroup `
            -z $cloudVmDnsZone `
            -n $dnsLinkName `
            --query 'name' -o tsv 2>$null

        if ($existingSpokeDnsLink) {
            Write-Host "  $spokeName - DNS zone link already exists. Skipping."
        } else {
            az network private-dns link vnet create `
                -g $HubResourceGroup `
                -z $cloudVmDnsZone `
                -n $dnsLinkName `
                --virtual-network $spoke.vnetId `
                --registration-enabled true `
                -o none
            Write-Host "  $spokeName - linked with auto-registration."
        }
    }

    # [10] vm-ad01 conditional forwarder: azure.internal -> Hub DNS Resolver
    Write-Host ''
    Write-Host "[10/$totalSteps] [On-prem] Configuring $DcVmName forwarder: $cloudVmDnsZone -> $hubDnsResolverInboundIp..." -ForegroundColor Yellow

    Invoke-Command -VMName $DcVmName -Credential $domainCred -ScriptBlock {
        param($ResolverIp, $Zone)

        $existing = Get-DnsServerZone -Name $Zone -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $Zone - already exists. Updating..."
            Set-DnsServerConditionalForwarderZone -Name $Zone -MasterServers $ResolverIp
        } else {
            Add-DnsServerConditionalForwarderZone -Name $Zone -MasterServers $ResolverIp
            Write-Host "  $Zone - created."
        }
    } -ArgumentList $hubDnsResolverInboundIp, $cloudVmDnsZone

    # Verify azure.internal
    $r4 = Invoke-Command -VMName $DcVmName -Credential $domainCred -ScriptBlock {
        param($Zone)
        Resolve-DnsName -Name $Zone -DnsOnly -ErrorAction SilentlyContinue
    } -ArgumentList $cloudVmDnsZone -ErrorAction SilentlyContinue
    Write-Host "  $cloudVmDnsZone resolution: $(if ($r4) { 'OK' } else { 'FAIL (expected if no VM registered)' })"
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ''
Write-Host '=== Hybrid DNS Setup Complete ===' -ForegroundColor Green
Write-Host ''
Write-Host 'DNS flow:' -ForegroundColor White
Write-Host '  Cloud -> contoso.local:'
Write-Host "    Spoke VM -> Hub DNS Resolver (Outbound) -> Forwarding Ruleset ($rulesetName)"
Write-Host "      -> VPN -> Host ($env:COMPUTERNAME, $hostPrivateIp) -> $DcVmName ($DcIp)"
Write-Host '  On-prem -> privatelink.*:'
Write-Host "    $DcVmName -> VPN -> Hub DNS Resolver (Inbound, $hubDnsResolverInboundIp) -> Private DNS Zone"
if ($EnableCloudVmResolution) {
    Write-Host "  On-prem -> ${cloudVmDnsZone}:"
    Write-Host "    $DcVmName -> VPN -> Hub DNS Resolver (Inbound, $hubDnsResolverInboundIp) -> Private DNS Zone ($cloudVmDnsZone)"
}
