<#
.SYNOPSIS
    VPN 接続の検証スクリプト (Nested Hyper-V 環境対応)
.DESCRIPTION
    Azure CLI でオンプレ側・Hub 側の VPN Gateway、Vnet2Vnet 接続、
    ルートテーブル、ピアリングの Gateway Transit 設定を確認する。
    Nested VM への到達性は az vm run-command + PowerShell Direct で検証。
.EXAMPLE
    .\Verify-VpnConnection.ps1
.EXAMPLE
    .\Verify-VpnConnection.ps1 -TestSpokeReachability
#>

[CmdletBinding()]
param(
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremVnetName = 'vnet-onprem',
    [string]$HubVnetName = 'vnet-hub',
    [string]$OnpremGatewayName = 'vgw-onprem',
    [string]$HubGatewayName = 'vpngw-hub',
    [string]$OnpremPipName = 'pip-vgw-onprem',
    [string]$RouteTableName = 'rt-block-internet',
    [string]$HostVmName = 'vm-onprem-hv01',
    [switch]$TestSpokeReachability
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# =============================================================================
# Helpers
# =============================================================================

function Test-Val ([string]$Label, [string]$Actual, [string]$Expected) {
    $ok = $Actual -eq $Expected
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Label, $Actual) -ForegroundColor $color
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-NotEmpty ([string]$Label, [string]$Actual) {
    $ok = -not [string]::IsNullOrWhiteSpace($Actual)
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Label, $(if ($ok) { $Actual } else { '(not found)' })) -ForegroundColor $color
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-Bool ([string]$Label, [bool]$Value) {
    $color = if ($Value) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $(if ($Value) { 'PASS' } else { 'FAIL' }), $Label) -ForegroundColor $color
    $script:total++; if ($Value) { $script:passed++ }
}

# =============================================================================
# 1. GatewaySubnet
# =============================================================================
Write-Host "`n=== 1. GatewaySubnet ===" -ForegroundColor Cyan

$onpremGwSnet = az network vnet subnet show -g $OnpremResourceGroup --vnet-name $OnpremVnetName -n GatewaySubnet `
    --query 'addressPrefix' -o tsv 2>$null
Test-NotEmpty "vnet-onprem/GatewaySubnet" $onpremGwSnet

$hubGwSnet = az network vnet subnet show -g $HubResourceGroup --vnet-name $HubVnetName -n GatewaySubnet `
    --query 'addressPrefix' -o tsv 2>$null
Test-NotEmpty "vnet-hub/GatewaySubnet" $hubGwSnet

# =============================================================================
# 2. VPN Gateway (On-prem)
# =============================================================================
Write-Host "`n=== 2. VPN Gateway (On-prem) ===" -ForegroundColor Cyan

$onpremGwJson = az network vnet-gateway show -g $OnpremResourceGroup -n $OnpremGatewayName `
    --query '{state:provisioningState, sku:sku.name, vpnType:vpnType}' -o json 2>$null
if ($onpremGwJson) {
    $onpremGw = $onpremGwJson | ConvertFrom-Json
    Test-Val  "$OnpremGatewayName provisioning" $onpremGw.state   'Succeeded'
    Test-Val  "$OnpremGatewayName SKU"          $onpremGw.sku     'VpnGw1AZ'
    Test-Val  "$OnpremGatewayName VPN type"     $onpremGw.vpnType 'RouteBased'
} else {
    Test-Val "$OnpremGatewayName" '(not found)' 'Succeeded'
}

$onpremPip = az network public-ip show -g $OnpremResourceGroup -n $OnpremPipName `
    --query 'ipAddress' -o tsv 2>$null
Test-NotEmpty "$OnpremPipName Public IP" $onpremPip

# =============================================================================
# 3. VPN Gateway (Hub)
# =============================================================================
Write-Host "`n=== 3. VPN Gateway (Hub) ===" -ForegroundColor Cyan

$hubGwJson = az network vnet-gateway show -g $HubResourceGroup -n $HubGatewayName `
    --query '{state:provisioningState, sku:sku.name, vpnType:vpnType}' -o json 2>$null
if ($hubGwJson) {
    $hubGw = $hubGwJson | ConvertFrom-Json
    Test-Val  "$HubGatewayName provisioning" $hubGw.state   'Succeeded'
    Test-Val  "$HubGatewayName SKU"          $hubGw.sku     'VpnGw1AZ'
    Test-Val  "$HubGatewayName VPN type"     $hubGw.vpnType 'RouteBased'
} else {
    Test-Val "$HubGatewayName" '(not found)' 'Succeeded'
}

# =============================================================================
# 4. VPN Connections (Vnet2Vnet, bidirectional)
# =============================================================================
Write-Host "`n=== 4. VPN Connections (Vnet2Vnet) ===" -ForegroundColor Cyan

# On-prem -> Hub
$cn1Json = az network vpn-connection show -g $OnpremResourceGroup -n cn-onprem-nested-to-hub `
    --query '{state:provisioningState, status:connectionStatus, type:connectionType}' -o json 2>$null
if ($cn1Json) {
    $cn1 = $cn1Json | ConvertFrom-Json
    Test-Val 'cn-onprem-nested-to-hub provisioning' $cn1.state  'Succeeded'
    Test-Val 'cn-onprem-nested-to-hub status'       $cn1.status 'Connected'
    Test-Val 'cn-onprem-nested-to-hub type'         $cn1.type   'Vnet2Vnet'
} else {
    Test-Val 'cn-onprem-nested-to-hub' '(not found)' 'Succeeded'
}

# Hub -> On-prem
$cn2Json = az network vpn-connection show -g $HubResourceGroup -n cn-hub-to-onprem-nested `
    --query '{state:provisioningState, status:connectionStatus, type:connectionType}' -o json 2>$null
if ($cn2Json) {
    $cn2 = $cn2Json | ConvertFrom-Json
    Test-Val 'cn-hub-to-onprem-nested provisioning' $cn2.state  'Succeeded'
    Test-Val 'cn-hub-to-onprem-nested status'       $cn2.status 'Connected'
    Test-Val 'cn-hub-to-onprem-nested type'         $cn2.type   'Vnet2Vnet'
} else {
    Test-Val 'cn-hub-to-onprem-nested' '(not found)' 'Succeeded'
}

# =============================================================================
# 5. Route Table (cloud routes via VPN Gateway)
# =============================================================================
Write-Host "`n=== 5. Route Table ($RouteTableName) ===" -ForegroundColor Cyan

$expectedPrefixes = @('10.10.0.0/16', '10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16')

$routesJson = az network route-table route list -g $OnpremResourceGroup --route-table-name $RouteTableName `
    --query "[?nextHopType=='VirtualNetworkGateway'].{name:name, prefix:addressPrefix}" -o json 2>$null
if ($routesJson) {
    $routes = $routesJson | ConvertFrom-Json
    $actualPrefixes = @($routes.prefix | Sort-Object)
    $expectedSorted = @($expectedPrefixes | Sort-Object)
    $allMatch = ($actualPrefixes -join ',') -eq ($expectedSorted -join ',')
    Test-Bool "VPN routes count: $($routes.Count) / $($expectedPrefixes.Count)" ($routes.Count -eq $expectedPrefixes.Count)
    Test-Bool "VPN routes match (Hub + Spoke1-4): $($actualPrefixes -join ', ')" $allMatch
} else {
    Test-Val 'VPN routes' '(not found)' 'present'
}

# Internet block route
$blockRoute = az network route-table route show -g $OnpremResourceGroup --route-table-name $RouteTableName `
    -n 'block-internet' --query '{prefix:addressPrefix, nextHop:nextHopType}' -o json 2>$null
if ($blockRoute) {
    $br = $blockRoute | ConvertFrom-Json
    Test-Val 'Internet block route (0.0.0.0/0 -> None)' $br.nextHop 'None'
} else {
    Write-Host "  [INFO] Internet block route name may differ" -ForegroundColor DarkGray
}

# =============================================================================
# 6. Connection Summary
# =============================================================================
Write-Host "`n=== 6. Connection Summary ===" -ForegroundColor Cyan

$hostIp = az vm list-ip-addresses -g $OnpremResourceGroup -n $HostVmName `
    --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>$null

Write-Host "  On-prem VPN GW PIP : $onpremPip" -ForegroundColor Gray
Write-Host "  On-prem GW Subnet  : $onpremGwSnet" -ForegroundColor Gray
Write-Host "  Hub GW Subnet      : $hubGwSnet" -ForegroundColor Gray
Write-Host "  Hyper-V Host IP    : $hostIp" -ForegroundColor Gray
Write-Host "  Connection (->Hub) : $(if ($cn1Json) { ($cn1Json | ConvertFrom-Json).status } else { '(not found)' })" -ForegroundColor Gray
Write-Host "  Connection (<-Hub) : $(if ($cn2Json) { ($cn2Json | ConvertFrom-Json).status } else { '(not found)' })" -ForegroundColor Gray

# =============================================================================
# 7. Hub-Spoke Peering Gateway Transit
# =============================================================================
Write-Host "`n=== 7. Hub-Spoke Peering Gateway Transit ===" -ForegroundColor Cyan

# Hub side: allowGatewayTransit = true
$hubPeerings = az network vnet peering list -g $HubResourceGroup --vnet-name $HubVnetName `
    --query '[].{name:name, gwTransit:allowGatewayTransit, state:peeringState}' -o json 2>$null | ConvertFrom-Json

foreach ($spoke in @('vnet-spoke1', 'vnet-spoke2', 'vnet-spoke3', 'vnet-spoke4')) {
    $p = $hubPeerings | Where-Object { $_.name -match $spoke }
    if ($p) {
        Test-Bool "Hub -> $spoke allowGatewayTransit" $p.gwTransit
        Test-Val  "Hub -> $spoke peeringState"        $p.state 'Connected'
    } else {
        Test-Val "Hub -> $spoke" '(not found)' 'Connected'
    }
}

# Spoke side: useRemoteGateways = true
foreach ($item in @(
    @{ rg = 'rg-spoke1'; vnet = 'vnet-spoke1' },
    @{ rg = 'rg-spoke2'; vnet = 'vnet-spoke2' },
    @{ rg = 'rg-spoke3'; vnet = 'vnet-spoke3' },
    @{ rg = 'rg-spoke4'; vnet = 'vnet-spoke4' }
)) {
    $sp = az network vnet peering list -g $item.rg --vnet-name $item.vnet `
        --query "[?contains(remoteVirtualNetwork.id,'vnet-hub')].useRemoteGateways | [0]" -o tsv 2>$null
    Test-Val "$($item.vnet) -> Hub useRemoteGateways" $sp 'true'
}

# =============================================================================
# 8. IP Reachability Tests (az vm run-command invoke)
# =============================================================================
Write-Host "`n=== 8. IP Reachability Tests ===" -ForegroundColor Cyan
Write-Host "  (az vm run-command invoke - each test takes 30-60 seconds)" -ForegroundColor DarkGray

# Discover Hub DNS Resolver Inbound IP
$hubDnsResolverIp = az dns-resolver inbound-endpoint show `
    -g $HubResourceGroup --dns-resolver-name dnspr-hub -n inbound `
    --query 'ipConfigurations[0].privateIpAddress' -o tsv 2>$null

if (-not $hubDnsResolverIp) {
    Write-Host "  [INFO] Hub DNS Resolver not found. Using 10.10.5.4 as fallback." -ForegroundColor DarkGray
    $hubDnsResolverIp = '10.10.5.4'
}

# --- Test A: Host -> Hub DNS Resolver (port 53) ---
$testLabel = "Host ($HostVmName) -> Hub DNS Resolver (${hubDnsResolverIp}:53)"
Write-Host "  Running: $testLabel..." -ForegroundColor Gray

$script1 = "Test-NetConnection -ComputerName '$hubDnsResolverIp' -Port 53 -WarningAction SilentlyContinue | Select-Object -ExpandProperty TcpTestSucceeded"
$result1 = az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $HostVmName `
    --command-id RunPowerShellScript `
    --scripts $script1 `
    --query 'value[0].message' -o tsv 2>$null
$reachable1 = ($result1 | Out-String) -match 'True'
Test-Bool $testLabel $reachable1

# --- Test B: Nested VM (vm-ad01) -> Hub DNS Resolver via PowerShell Direct ---
$testLabel2 = "Nested VM (vm-ad01) -> Hub DNS Resolver (${hubDnsResolverIp}:53)"
Write-Host "  Running: $testLabel2..." -ForegroundColor Gray
Write-Host "  (2-stage: az vm run-command -> PowerShell Direct)" -ForegroundColor DarkGray

$nestedScript = @"
`$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', `$pw)
try {
    `$r = Invoke-Command -VMName 'vm-ad01' -Credential `$cred -ScriptBlock {
        Test-NetConnection -ComputerName '$hubDnsResolverIp' -Port 53 -WarningAction SilentlyContinue |
            Select-Object -ExpandProperty TcpTestSucceeded
    } -ErrorAction Stop
    Write-Output `$r
} catch {
    Write-Output "ERROR: `$(`$_.Exception.Message)"
}
"@

$result2 = az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $HostVmName `
    --command-id RunPowerShellScript `
    --scripts $nestedScript `
    --query 'value[0].message' -o tsv 2>$null
$reachable2 = ($result2 | Out-String) -match 'True'
Test-Bool $testLabel2 $reachable2

# --- Test C: Host -> Hub VNet (10.10.0.1 ICMP) ---
$testLabel3 = "Host ($HostVmName) -> Hub VNet (10.10.0.1 ping)"
Write-Host "  Running: $testLabel3..." -ForegroundColor Gray

$script3 = "Test-Connection -ComputerName '10.10.0.1' -Count 2 -Quiet"
$result3 = az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $HostVmName `
    --command-id RunPowerShellScript `
    --scripts $script3 `
    --query 'value[0].message' -o tsv 2>$null
$reachable3 = ($result3 | Out-String) -match 'True'
Test-Bool $testLabel3 $reachable3

# =============================================================================
# 9. Spoke VM Reachability Tests (optional)
# =============================================================================
if ($TestSpokeReachability) {
    Write-Host "`n=== 9. Spoke VM Discovery + Reachability ===" -ForegroundColor Cyan
    Write-Host "  Discovering Spoke VMs and testing bidirectional reachability" -ForegroundColor DarkGray
    Write-Host "  (Each test takes 30-60 seconds. FW policy may cause FAIL)" -ForegroundColor DarkGray

    $spokeRgs = @(
        @{ rg = 'rg-spoke1'; label = 'Spoke1' }
        @{ rg = 'rg-spoke2'; label = 'Spoke2' }
        @{ rg = 'rg-spoke3'; label = 'Spoke3' }
        @{ rg = 'rg-spoke4'; label = 'Spoke4' }
    )

    $discoveredVms = @()

    foreach ($spoke in $spokeRgs) {
        $vmsJson = az vm list -g $spoke.rg `
            --query '[].{name:name, nicId:networkProfile.networkInterfaces[0].id}' `
            -o json 2>$null
        if (-not $vmsJson -or $vmsJson -eq '[]') {
            Write-Host "  [$($spoke.label)] No VMs - skipped" -ForegroundColor DarkGray
            continue
        }
        $vms = $vmsJson | ConvertFrom-Json
        foreach ($vm in $vms) {
            $privateIp = az network nic show --ids $vm.nicId `
                --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>$null
            if ($privateIp) {
                Write-Host "  [$($spoke.label)] $($vm.name) -> $privateIp" -ForegroundColor Gray
                $discoveredVms += @{
                    rg    = $spoke.rg
                    label = $spoke.label
                    name  = $vm.name
                    ip    = $privateIp
                }
            }
        }
    }

    if ($discoveredVms.Count -eq 0) {
        Write-Host "  No Spoke VMs found. Skipping reachability tests." -ForegroundColor DarkGray
    } else {
        Write-Host "  Discovered $($discoveredVms.Count) Spoke VM(s)" -ForegroundColor Green

        foreach ($vm in $discoveredVms) {
            # Host -> Spoke VM (RDP 3389)
            $fwdLabel = "Host ($HostVmName) -> $($vm.label) ($($vm.name) $($vm.ip):3389)"
            Write-Host "  Running: $fwdLabel..." -ForegroundColor Gray
            $fwdScript = "Test-NetConnection -ComputerName '$($vm.ip)' -Port 3389 -WarningAction SilentlyContinue | Select-Object -ExpandProperty TcpTestSucceeded"
            $fwdResult = az vm run-command invoke `
                --resource-group $OnpremResourceGroup `
                --name $HostVmName `
                --command-id RunPowerShellScript `
                --scripts $fwdScript `
                --query 'value[0].message' -o tsv 2>$null
            Test-Bool $fwdLabel (($fwdResult | Out-String) -match 'True')

            # Spoke VM -> Host
            $revLabel = "$($vm.label) ($($vm.name)) -> Host ($hostIp)"
            Write-Host "  Running: $revLabel..." -ForegroundColor Gray
            $revScript = "Test-NetConnection -ComputerName '$hostIp' -Port 3389 -WarningAction SilentlyContinue | Select-Object -ExpandProperty TcpTestSucceeded"
            $revResult = az vm run-command invoke `
                --resource-group $vm.rg `
                --name $vm.name `
                --command-id RunPowerShellScript `
                --scripts $revScript `
                --query 'value[0].message' -o tsv 2>$null
            Test-Bool $revLabel (($revResult | Out-String) -match 'True')
        }
    }
} else {
    Write-Host "`n=== 9. Spoke VM Reachability: Skipped (use -TestSpokeReachability) ===" -ForegroundColor DarkGray
}

# =============================================================================
# Summary
# =============================================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== Result: {0} / {1} passed ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  Review [FAIL] items above." -ForegroundColor Yellow
}
