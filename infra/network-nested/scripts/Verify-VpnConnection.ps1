<#
.SYNOPSIS
    VPN 接続の検証スクリプト (Nested Hyper-V 環境対応)
.DESCRIPTION
    Azure CLI でオンプレ側・Hub 側の VPN Gateway、S2S VPN 接続、
    LGW、ピアリングの Gateway Transit 設定を確認する。
    Nested VM への到達性は az vm run-command + PowerShell Direct で検証。
.EXAMPLE
    .\Verify-VpnConnection.ps1
.EXAMPLE
    .\Verify-VpnConnection.ps1 -NestedAdminUser 'YOURDOM\Admin' -NestedAdminPassword 'YourP@ss'
.EXAMPLE
    .\Verify-VpnConnection.ps1 -TestSpokeReachability
#>

[CmdletBinding()]
param(
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremVnetName = 'vnet-onprem-nested',
    [string]$HubVnetName = 'vnet-hub',
    [string]$OnpremGatewayName = 'vgw-onprem',
    [string]$HubGatewayName = 'vpngw-hub',
    [string]$OnpremPipName = 'pip-vgw-onprem',
    [string]$HostVmName = 'vm-onprem-nested-hv01',
    [string]$NestedAdminUser = '',
    [string]$NestedAdminPassword = '',
    [switch]$TestSpokeReachability
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# =============================================================================
# ヘルパー
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
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Label, $(if ($ok) { $Actual } else { '(未検出)' })) -ForegroundColor $color
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
Test-NotEmpty "vnet-onprem-nested/GatewaySubnet" $onpremGwSnet

$hubGwSnet = az network vnet subnet show -g $HubResourceGroup --vnet-name $HubVnetName -n GatewaySubnet `
    --query 'addressPrefix' -o tsv 2>$null
Test-NotEmpty "vnet-hub/GatewaySubnet" $hubGwSnet

# =============================================================================
# 2. VPN Gateway (On-prem)
# =============================================================================
Write-Host "`n=== 2. VPN Gateway (オンプレ側) ===" -ForegroundColor Cyan

$onpremGwJson = az network vnet-gateway show -g $OnpremResourceGroup -n $OnpremGatewayName `
    --query '{state:provisioningState, sku:sku.name, vpnType:vpnType}' -o json 2>$null
if ($onpremGwJson) {
    $onpremGw = $onpremGwJson | ConvertFrom-Json
    Test-Val  "$OnpremGatewayName プロビジョニング" $onpremGw.state   'Succeeded'
    Test-Val  "$OnpremGatewayName SKU"              $onpremGw.sku     'VpnGw1AZ'
    Test-Val  "$OnpremGatewayName VPN タイプ"        $onpremGw.vpnType 'RouteBased'
} else {
    Test-Val "$OnpremGatewayName" '(未検出)' 'Succeeded'
}

$onpremPip = az network public-ip show -g $OnpremResourceGroup -n $OnpremPipName `
    --query 'ipAddress' -o tsv 2>$null
Test-NotEmpty "$OnpremPipName Public IP" $onpremPip

# =============================================================================
# 3. VPN Gateway (Hub)
# =============================================================================
Write-Host "`n=== 3. VPN Gateway (Hub 側) ===" -ForegroundColor Cyan

$hubGwJson = az network vnet-gateway show -g $HubResourceGroup -n $HubGatewayName `
    --query '{state:provisioningState, sku:sku.name, vpnType:vpnType}' -o json 2>$null
if ($hubGwJson) {
    $hubGw = $hubGwJson | ConvertFrom-Json
    Test-Val  "$HubGatewayName プロビジョニング" $hubGw.state   'Succeeded'
    Test-Val  "$HubGatewayName SKU"              $hubGw.sku     'VpnGw1AZ'
    Test-Val  "$HubGatewayName VPN タイプ"        $hubGw.vpnType 'RouteBased'
} else {
    Test-Val "$HubGatewayName" '(未検出)' 'Succeeded'
}

$hubPip = az network public-ip show -g $HubResourceGroup -n "$HubGatewayName-pip1" `
    --query 'ipAddress' -o tsv 2>$null
Test-NotEmpty 'vpngw-hub Public IP' $hubPip

# =============================================================================
# 4. Local Network Gateway
# =============================================================================
Write-Host "`n=== 4. Local Network Gateway ===" -ForegroundColor Cyan

# lgw-hub (in onprem RG — represents Hub side)
$lgwHubJson = az network local-gateway show -g $OnpremResourceGroup -n lgw-hub `
    --query '{state:provisioningState, gwIp:gatewayIpAddress, prefixes:localNetworkAddressSpace.addressPrefixes}' `
    -o json 2>$null
if ($lgwHubJson) {
    $lgwHub = $lgwHubJson | ConvertFrom-Json
    Test-Val 'lgw-hub プロビジョニング' $lgwHub.state 'Succeeded'
    # LGW の gatewayIpAddress が Hub VPN Gateway の PIP と一致するか
    if ($hubPip) {
        Test-Val 'lgw-hub -> Hub PIP 一致' $lgwHub.gwIp $hubPip
    } else {
        Test-NotEmpty 'lgw-hub Gateway IP' $lgwHub.gwIp
    }
    # アドレス空間: Hub + Spoke1-4
    $expectedPrefixes = @('10.10.0.0/16', '10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16')
    $actualPrefixes = @($lgwHub.prefixes | Sort-Object)
    $expectedSorted = @($expectedPrefixes | Sort-Object)
    $prefixMatch = ($actualPrefixes -join ',') -eq ($expectedSorted -join ',')
    Test-Bool "lgw-hub アドレス空間 (Hub + Spoke1-4: $($actualPrefixes -join ', '))" $prefixMatch
} else {
    Test-Val 'lgw-hub' '(未検出)' 'Succeeded'
}

# lgw-onprem-nested (in Hub RG — represents OnPrem side)
$lgwOnpremJson = az network local-gateway show -g $HubResourceGroup -n lgw-onprem-nested `
    --query '{state:provisioningState, gwIp:gatewayIpAddress, prefixes:localNetworkAddressSpace.addressPrefixes}' `
    -o json 2>$null
if ($lgwOnpremJson) {
    $lgwOnprem = $lgwOnpremJson | ConvertFrom-Json
    Test-Val 'lgw-onprem-nested プロビジョニング' $lgwOnprem.state 'Succeeded'
    if ($onpremPip) {
        Test-Val 'lgw-onprem-nested -> OnPrem PIP 一致' $lgwOnprem.gwIp $onpremPip
    } else {
        Test-NotEmpty 'lgw-onprem-nested Gateway IP' $lgwOnprem.gwIp
    }
    Test-Bool "lgw-onprem-nested アドレス空間: $($lgwOnprem.prefixes -join ', ')" ($lgwOnprem.prefixes -contains '10.1.0.0/16')
} else {
    Test-Val 'lgw-onprem-nested' '(未検出)' 'Succeeded'
}

# =============================================================================
# 5. S2S VPN Connections (IPsec, bidirectional)
# =============================================================================
Write-Host "`n=== 5. S2S VPN 接続 ===" -ForegroundColor Cyan

# OnPrem -> Hub
$cn1Json = az network vpn-connection show -g $OnpremResourceGroup -n cn-onprem-nested-to-hub `
    --query '{state:provisioningState, status:connectionStatus, protocol:connectionProtocol, type:connectionType}' -o json 2>$null
if ($cn1Json) {
    $cn1 = $cn1Json | ConvertFrom-Json
    Test-Val 'cn-onprem-nested-to-hub プロビジョニング' $cn1.state    'Succeeded'
    Test-Val 'cn-onprem-nested-to-hub 接続状態'         $cn1.status   'Connected'
    Test-Val 'cn-onprem-nested-to-hub タイプ'           $cn1.type     'IPsec'
    Test-Val 'cn-onprem-nested-to-hub プロトコル'        $cn1.protocol 'IKEv2'
} else {
    Test-Val 'cn-onprem-nested-to-hub' '(未検出)' 'Succeeded'
}

# Hub -> OnPrem
$cn2Json = az network vpn-connection show -g $HubResourceGroup -n cn-hub-to-onprem-nested `
    --query '{state:provisioningState, status:connectionStatus, protocol:connectionProtocol, type:connectionType}' -o json 2>$null
if ($cn2Json) {
    $cn2 = $cn2Json | ConvertFrom-Json
    Test-Val 'cn-hub-to-onprem-nested プロビジョニング' $cn2.state    'Succeeded'
    Test-Val 'cn-hub-to-onprem-nested 接続状態'         $cn2.status   'Connected'
    Test-Val 'cn-hub-to-onprem-nested タイプ'           $cn2.type     'IPsec'
    Test-Val 'cn-hub-to-onprem-nested プロトコル'        $cn2.protocol 'IKEv2'
} else {
    Test-Val 'cn-hub-to-onprem-nested' '(未検出)' 'Succeeded'
}

# =============================================================================
# 6. Connection Summary
# =============================================================================
Write-Host "`n=== 6. 接続情報サマリ ===" -ForegroundColor Cyan

$hostIp = az vm list-ip-addresses -g $OnpremResourceGroup -n $HostVmName `
    --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>$null

Write-Host "  オンプレ VPN GW PIP  : $onpremPip" -ForegroundColor Gray
Write-Host "  Hub VPN GW PIP       : $hubPip" -ForegroundColor Gray
Write-Host "  Hyper-V ホスト IP    : $hostIp" -ForegroundColor Gray
Write-Host "  LGW (lgw-hub)        : $(if ($lgwHubJson) { ($lgwHubJson | ConvertFrom-Json).gwIp } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  LGW (lgw-onprem)     : $(if ($lgwOnpremJson) { ($lgwOnpremJson | ConvertFrom-Json).gwIp } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  接続状態 (->Hub)      : $(if ($cn1Json) { ($cn1Json | ConvertFrom-Json).status } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  接続状態 (<-Hub)      : $(if ($cn2Json) { ($cn2Json | ConvertFrom-Json).status } else { '(未検出)' })" -ForegroundColor Gray

# =============================================================================
# 7. Hub-Spoke Peering Gateway Transit
# =============================================================================
Write-Host "`n=== 7. Hub-Spoke ピアリング Gateway Transit ===" -ForegroundColor Cyan

# Hub 側: allowGatewayTransit = true
$hubPeerings = az network vnet peering list -g $HubResourceGroup --vnet-name $HubVnetName `
    --query '[].{name:name, gwTransit:allowGatewayTransit, state:peeringState}' -o json 2>$null | ConvertFrom-Json

foreach ($spoke in @('vnet-spoke1', 'vnet-spoke2', 'vnet-spoke3', 'vnet-spoke4')) {
    $p = $hubPeerings | Where-Object { $_.name -match $spoke }
    if ($p) {
        Test-Bool "Hub -> $spoke allowGatewayTransit" $p.gwTransit
        Test-Val  "Hub -> $spoke peeringState"        $p.state 'Connected'
    } else {
        Test-Val "Hub -> $spoke" '(未検出)' 'Connected'
    }
}

# Spoke 側: useRemoteGateways = true
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
Write-Host "`n=== 8. IP 到達性テスト ===" -ForegroundColor Cyan

# VPN 接続が未デプロイならスキップ
if (-not $cn1Json) {
    Write-Host "  [SKIP] VPN 接続 (cn-onprem-nested-to-hub) が未デプロイのためスキップ" -ForegroundColor DarkGray
} else {

Write-Host "  (az vm run-command invoke を使用 — 各テストに 30〜60 秒かかります)" -ForegroundColor DarkGray

# Discover Hub DNS Resolver Inbound IP
$hubDnsResolverIp = az dns-resolver inbound-endpoint show `
    -g $HubResourceGroup --dns-resolver-name dnspr-hub -n inbound `
    --query 'ipConfigurations[0].privateIpAddress' -o tsv 2>$null

if (-not $hubDnsResolverIp) {
    Write-Host "  [INFO] Hub DNS Resolver が見つかりません。10.10.5.4 をフォールバックとして使用します。" -ForegroundColor DarkGray
    $hubDnsResolverIp = '10.10.5.4'
}

# --- Test A: Host -> Hub DNS Resolver (port 53) ---
$testLabel = "Host ($HostVmName) -> Hub DNS Resolver (${hubDnsResolverIp}:53)"
Write-Host "  リモートコマンド実行中: $testLabel..." -ForegroundColor Gray

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
if ([string]::IsNullOrWhiteSpace($NestedAdminUser) -or [string]::IsNullOrWhiteSpace($NestedAdminPassword)) {
    Write-Host "  [SKIP] Nested VM テスト — NestedAdminUser/NestedAdminPassword が未指定" -ForegroundColor DarkGray
} else {
    $testLabel2 = "Nested VM (vm-ad01) -> Hub DNS Resolver (${hubDnsResolverIp}:53)"
    Write-Host "  リモートコマンド実行中: $testLabel2..." -ForegroundColor Gray
    Write-Host "  (2段階: az vm run-command -> PowerShell Direct)" -ForegroundColor DarkGray

    $nestedScript = @"
`$pw = ConvertTo-SecureString '$NestedAdminPassword' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('$NestedAdminUser', `$pw)
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
}

# --- Test C: Host -> Hub VNet (10.10.0.1 ICMP) ---
$testLabel3 = "Host ($HostVmName) -> Hub VNet (10.10.0.1 ping)"
Write-Host "  リモートコマンド実行中: $testLabel3..." -ForegroundColor Gray

$script3 = "Test-Connection -ComputerName '10.10.0.1' -Count 2 -Quiet"
$result3 = az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $HostVmName `
    --command-id RunPowerShellScript `
    --scripts $script3 `
    --query 'value[0].message' -o tsv 2>$null
$reachable3 = ($result3 | Out-String) -match 'True'
Test-Bool $testLabel3 $reachable3

} # end VPN 接続スキップガード

# =============================================================================
# 9. Spoke VM 動的検出 + 双方向到達性テスト (オプション)
# =============================================================================

# VPN 接続が未デプロイならスキップ
if (-not $cn1Json) {
    if ($TestSpokeReachability) {
        Write-Host "`n=== 9. Spoke VM 動的検出 + 双方向到達性テスト ===" -ForegroundColor Cyan
        Write-Host "  [SKIP] VPN 接続 (cn-onprem-nested-to-hub) が未デプロイのためスキップ" -ForegroundColor DarkGray
    }
} elseif ($TestSpokeReachability) {
    Write-Host "`n=== 9. Spoke VM 動的検出 + 双方向到達性テスト ===" -ForegroundColor Cyan
    Write-Host "  Spoke RG 内の VM を検索し、オンプレ<->Spoke 間の IP 到達性をテストします" -ForegroundColor DarkGray
    Write-Host "  (各テストに 30～60 秒かかります。FW ポリシーにより FAIL になる場合があります)" -ForegroundColor DarkGray

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
            Write-Host "  [$($spoke.label)] VM なし — スキップ" -ForegroundColor DarkGray
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
        Write-Host "  Spoke VM が見つかりませんでした。テストをスキップします。" -ForegroundColor DarkGray
    } else {
        Write-Host "  $($discoveredVms.Count) 台の Spoke VM を検出しました" -ForegroundColor Green

        foreach ($vm in $discoveredVms) {
            # Host -> Spoke VM (RDP 3389)
            $fwdLabel = "Host ($HostVmName) -> $($vm.label) ($($vm.name) $($vm.ip):3389)"
            Write-Host "  リモートコマンド実行中: $fwdLabel..." -ForegroundColor Gray
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
            Write-Host "  リモートコマンド実行中: $revLabel..." -ForegroundColor Gray
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
    Write-Host "`n=== 9. Spoke VM 到達性テスト: スキップ (use -TestSpokeReachability to enable) ===" -ForegroundColor DarkGray
}

# =============================================================================
# サマリ
# =============================================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}
