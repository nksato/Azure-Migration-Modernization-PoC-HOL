# =============================================================================
# Configure-Dns.ps1
# Run on Hyper-V host via Bastion: Configure bidirectional DNS forwarding
#
# This script:
#   1. Installs DNS Server role on the Hyper-V host
#   2. Configures conditional forwarder: contoso.local -> vm-ad01 (192.168.100.10)
#   3. Configures conditional forwarders on vm-ad01: privatelink.* -> Hub DNS Resolver
#   4. (Optional) Configures conditional forwarder on vm-ad01: azure.internal -> Hub DNS Resolver
#   5. Verification with detailed diagnostics
#
# Prerequisites:
#   - VPN connection established (vpn-deploy.bicep)
#   - DNS forwarding ruleset deployed (dns-deploy.bicep)
#   - AD DS installed on vm-ad01 (Install-ADDS.ps1)
#
# Usage:
#   .\Configure-Dns.ps1 -HubDnsResolverInboundIp 10.10.5.4
#   .\Configure-Dns.ps1 -HubDnsResolverInboundIp 10.10.5.4 -EnableCloudVmResolution
#
# To find the Hub DNS Resolver Inbound IP:
#   az dns-resolver inbound-endpoint show -g rg-hub --dns-resolver-name dnspr-hub -n inbound --query "ipConfigurations[0].privateIpAddress" -o tsv
# =============================================================================

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory = $true)]
    [string]$HubDnsResolverInboundIp,

    [switch]$EnableCloudVmResolution
)

$ErrorActionPreference = 'Stop'

$dcIp = '192.168.100.10'
$domainName = 'contoso.local'

$domainPassword = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$domainCred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $domainPassword)

# Private DNS zones used by the cloud environment
$privateLinkZones = @(
    'privatelink.database.windows.net'
    'privatelink.blob.core.windows.net'
    'privatelink.vaultcore.azure.net'
    'privatelink.azurewebsites.net'
)

$cloudVmDnsZone = 'azure.internal'

Write-Host '=== Hybrid DNS Setup ===' -ForegroundColor Cyan
Write-Host "  [1/5] Host DNS Server role" -ForegroundColor Cyan
Write-Host "  [2/5] Host -> contoso.local: forwarder to vm-ad01 ($dcIp)" -ForegroundColor Cyan
Write-Host "  [3/5] vm-ad01 -> privatelink.*: forwarder to Hub DNS Resolver ($HubDnsResolverInboundIp)" -ForegroundColor Cyan
if ($EnableCloudVmResolution) {
    Write-Host "  [4/5] vm-ad01 -> $cloudVmDnsZone: forwarder to Hub DNS Resolver ($HubDnsResolverInboundIp)" -ForegroundColor Cyan
} else {
    Write-Host '  [4/5] Cloud VM resolution skipped (use -EnableCloudVmResolution to enable)' -ForegroundColor DarkGray
}
Write-Host '  [5/5] Verification' -ForegroundColor Cyan
Write-Host ''

# ============================================================================
# [1/5] Install DNS Server role on Hyper-V host
# ============================================================================
Write-Host '[1/5] Installing DNS Server role on host...' -ForegroundColor Yellow

if ((Get-WindowsFeature DNS).Installed) {
    Write-Host "  DNS Server role already installed. Skipping."
} else {
    Install-WindowsFeature DNS -IncludeManagementTools
    Write-Host "  DNS Server role installed."
}

# ============================================================================
# [2/5] Configure host DNS - forward contoso.local to vm-ad01
# ============================================================================
Write-Host ''
Write-Host "[2/5] Configuring host DNS forwarder: $domainName -> $dcIp (vm-ad01)..." -ForegroundColor Yellow

$existingForwarder = Get-DnsServerZone -Name $domainName -ErrorAction SilentlyContinue
if ($existingForwarder) {
    Write-Host "  Conditional forwarder for $domainName already exists. Updating..."
    Set-DnsServerConditionalForwarderZone -Name $domainName -MasterServers $dcIp
} else {
    Add-DnsServerConditionalForwarderZone -Name $domainName -MasterServers $dcIp
    Write-Host "  Conditional forwarder created."
}

# Verify
$resolved = Resolve-DnsName -Name $domainName -DnsOnly -ErrorAction SilentlyContinue
if ($resolved) {
    Write-Host "  Verification: $domainName resolved successfully."
} else {
    Write-Host "  Warning: $domainName resolution failed. Check VPN and vm-ad01 status."
}

# ============================================================================
# [3/5] Configure vm-ad01 DNS - forward privatelink.* to Hub DNS Resolver
# ============================================================================
Write-Host ''
Write-Host "[3/5] Configuring vm-ad01 conditional forwarders: privatelink.* -> $HubDnsResolverInboundIp..." -ForegroundColor Yellow

Invoke-Command -VMName 'vm-ad01' -Credential $domainCred -ScriptBlock {
    param($ResolverIp, $Zones)

    foreach ($zone in $Zones) {
        $existing = Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $zone - already exists. Updating..."
            Set-DnsServerConditionalForwarderZone -Name $zone -MasterServers $ResolverIp
        } else {
            Add-DnsServerConditionalForwarderZone -Name $zone -MasterServers $ResolverIp
            Write-Host "  $zone - conditional forwarder created."
        }
    }
} -ArgumentList $HubDnsResolverInboundIp, $privateLinkZones

# ============================================================================
# [4/5] (Optional) Configure vm-ad01 DNS - forward azure.internal to Hub DNS Resolver
# ============================================================================
if ($EnableCloudVmResolution) {
    Write-Host ''
    Write-Host "[4/5] Configuring vm-ad01 conditional forwarder: $cloudVmDnsZone -> $HubDnsResolverInboundIp..." -ForegroundColor Yellow

    Invoke-Command -VMName 'vm-ad01' -Credential $domainCred -ScriptBlock {
        param($ResolverIp, $Zone)

        $existing = Get-DnsServerZone -Name $Zone -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $Zone - already exists. Updating..."
            Set-DnsServerConditionalForwarderZone -Name $Zone -MasterServers $ResolverIp
        } else {
            Add-DnsServerConditionalForwarderZone -Name $Zone -MasterServers $ResolverIp
            Write-Host "  $Zone - conditional forwarder created."
        }
    } -ArgumentList $HubDnsResolverInboundIp, $cloudVmDnsZone

    Write-Host '  Cloud VM resolution configured.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '[4/5] Cloud VM resolution skipped (use -EnableCloudVmResolution to enable).' -ForegroundColor DarkGray
}

# ============================================================================
# [5/5] Verification
# ============================================================================
Write-Host ''
Write-Host '[5/5] Verification' -ForegroundColor Yellow
Write-Host ''

# --- Host DNS Server zones ---
Write-Host 'Host DNS Server - Conditional Forwarders:' -ForegroundColor White
Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' } |
    Format-Table ZoneName, ZoneType, MasterServers -AutoSize

# --- vm-ad01 DNS Server zones ---
Write-Host 'vm-ad01 DNS Server - Conditional Forwarders:' -ForegroundColor White
Invoke-Command -VMName 'vm-ad01' -Credential $domainCred -ScriptBlock {
    Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' } |
        Format-Table ZoneName, ZoneType, MasterServers -AutoSize
}

# --- Resolution tests ---
Write-Host 'Resolution Tests:' -ForegroundColor White
$testResults = @()

# Test 1: host -> contoso.local
$r1 = Resolve-DnsName -Name $domainName -DnsOnly -ErrorAction SilentlyContinue
$testResults += [PSCustomObject]@{ From = 'Host'; Query = $domainName; Result = if ($r1) { 'OK' } else { 'FAIL' } }

# Test 2: vm-ad01 -> privatelink.database.windows.net
$r2 = Invoke-Command -VMName 'vm-ad01' -Credential $domainCred -ScriptBlock {
    Resolve-DnsName -Name 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
} -ErrorAction SilentlyContinue
$testResults += [PSCustomObject]@{ From = 'vm-ad01'; Query = 'privatelink.database.windows.net'; Result = if ($r2) { 'OK' } else { 'FAIL (expected if no SQL PE)' } }

# Test 3: vm-app01 -> privatelink.database.windows.net (end-to-end)
$r3 = Invoke-Command -VMName 'vm-app01' -Credential $domainCred -ScriptBlock {
    Resolve-DnsName -Name 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
} -ErrorAction SilentlyContinue
$testResults += [PSCustomObject]@{ From = 'vm-app01'; Query = 'privatelink.database.windows.net'; Result = if ($r3) { 'OK' } else { 'FAIL (expected if no SQL PE)' } }

if ($EnableCloudVmResolution) {
    $r4 = Invoke-Command -VMName 'vm-ad01' -Credential $domainCred -ScriptBlock {
        param($Zone)
        Resolve-DnsName -Name $Zone -DnsOnly -ErrorAction SilentlyContinue
    } -ArgumentList $cloudVmDnsZone -ErrorAction SilentlyContinue
    $testResults += [PSCustomObject]@{ From = 'vm-ad01'; Query = $cloudVmDnsZone; Result = if ($r4) { 'OK' } else { 'FAIL (expected if no VM registered)' } }
}

$testResults | Format-Table From, Query, Result -AutoSize

Write-Host ''
Write-Host '=== Hybrid DNS Setup Complete ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'DNS flow:' -ForegroundColor White
Write-Host '  Cloud -> contoso.local:'
Write-Host "    Hub DNS Resolver (Outbound) -> VPN -> Host ($env:COMPUTERNAME) -> vm-ad01"
Write-Host '  On-prem -> privatelink.*:'
Write-Host "    vm-ad01 -> VPN -> Hub DNS Resolver (Inbound, $HubDnsResolverInboundIp) -> Private DNS Zone"
if ($EnableCloudVmResolution) {
    Write-Host "  On-prem -> ${cloudVmDnsZone}:"
    Write-Host "    vm-ad01 -> VPN -> Hub DNS Resolver (Inbound, $HubDnsResolverInboundIp) -> Private DNS Zone ($cloudVmDnsZone)"
}
