<#
.SYNOPSIS
    VPN Gateway 配置・接続の状態を検証する
.DESCRIPTION
    Azure CLI でオンプレ側・Hub 側の VPN Gateway、S2S 接続、
    LGW、ピアリングの Gateway Transit 設定を確認する。
    Azure API のみで完結する簡易チェック。
.EXAMPLE
    .\Verify-VpnConnection.ps1
.EXAMPLE
    .\Verify-VpnConnection.ps1 -TestSpokeReachability
#>

[CmdletBinding()]
param(
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremVnetName = 'vnet-onprem',
    [string]$HubVnetName = 'vnet-hub',
    [string]$OnpremGatewayName = 'vgw-onprem',
    [string]$HubGatewayName = 'vpngw-hub',
    [string]$OnpremPipName = 'vgw-onprem-pip1',
    [string]$OnpremVmName = 'vm-onprem-ad',
    [string]$OnpremConnectionName = 'cn-onprem-to-hub',
    [string]$HubConnectionName = 'cn-hub-to-onprem',
    [string]$OnpremLgwName = 'lgw-hub',
    [string]$HubLgwName = 'lgw-onprem',
    [switch]$TestSpokeReachability
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# --- ヘルパー ---

function Test-Val ([string]$Label, [string]$Actual, [string]$Expected) {
    $ok = $Actual -eq $Expected
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($ok) {'PASS'} else {'FAIL'}), $Label, $Actual) -ForegroundColor $color
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-NotEmpty ([string]$Label, [string]$Actual) {
    $ok = -not [string]::IsNullOrWhiteSpace($Actual)
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($ok) {'PASS'} else {'FAIL'}), $Label, $(if ($ok) {$Actual} else {'(未検出)'})) -ForegroundColor $color
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-Bool ([string]$Label, [bool]$Value) {
    $color = if ($Value) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $(if ($Value) {'PASS'} else {'FAIL'}), $Label) -ForegroundColor $color
    $script:total++; if ($Value) { $script:passed++ }
}

# ============================================================
# 1. GatewaySubnet
# ============================================================
Write-Host "`n=== 1. GatewaySubnet ===" -ForegroundColor Cyan

$onpremGwSnet = az network vnet subnet show -g $OnpremResourceGroup --vnet-name $OnpremVnetName -n GatewaySubnet `
    --query "addressPrefix" -o tsv 2>$null
Test-NotEmpty "$OnpremVnetName/GatewaySubnet" $onpremGwSnet

$hubGwSnet = az network vnet subnet show -g $HubResourceGroup --vnet-name $HubVnetName -n GatewaySubnet `
    --query "addressPrefix" -o tsv 2>$null
Test-NotEmpty "$HubVnetName/GatewaySubnet" $hubGwSnet

# ============================================================
# 2. VPN Gateway (オンプレ側)
# ============================================================
Write-Host "`n=== 2. VPN Gateway (オンプレ側) ===" -ForegroundColor Cyan

$onpremGwJson = az network vnet-gateway show -g $OnpremResourceGroup -n $OnpremGatewayName `
    --query '{state:provisioningState, sku:sku.name, vpnType:vpnType}' -o json 2>$null
if ($onpremGwJson) {
    $onpremGw = $onpremGwJson | ConvertFrom-Json
    Test-Val  "$OnpremGatewayName プロビジョニング" $onpremGw.state   'Succeeded'
    Test-Val  "$OnpremGatewayName SKU"              $onpremGw.sku     'VpnGw1AZ'
    Test-Val  "$OnpremGatewayName VPN タイプ"        $onpremGw.vpnType 'RouteBased'
} else {
    Test-Val $OnpremGatewayName '(未検出)' 'Succeeded'
}

$onpremPip = az network public-ip show -g $OnpremResourceGroup -n $OnpremPipName `
    --query 'ipAddress' -o tsv 2>$null
Test-NotEmpty "$OnpremPipName Public IP" $onpremPip

# ============================================================
# 3. VPN Gateway (Hub 側)
# ============================================================
Write-Host "`n=== 3. VPN Gateway (Hub 側) ===" -ForegroundColor Cyan

$hubGwJson = az network vnet-gateway show -g $HubResourceGroup -n $HubGatewayName `
    --query '{state:provisioningState, sku:sku.name, vpnType:vpnType}' -o json 2>$null
if ($hubGwJson) {
    $hubGw = $hubGwJson | ConvertFrom-Json
    Test-Val  "$HubGatewayName プロビジョニング" $hubGw.state   'Succeeded'
    Test-Val  "$HubGatewayName SKU"              $hubGw.sku     'VpnGw1AZ'
    Test-Val  "$HubGatewayName VPN タイプ"        $hubGw.vpnType 'RouteBased'
} else {
    Test-Val $HubGatewayName '(未検出)' 'Succeeded'
}

$hubPip = az network public-ip show -g $HubResourceGroup -n "$HubGatewayName-pip1" `
    --query 'ipAddress' -o tsv 2>$null
Test-NotEmpty "$HubGatewayName Public IP" $hubPip

# ============================================================
# 4. Local Network Gateway
# ============================================================
Write-Host "`n=== 4. Local Network Gateway ===" -ForegroundColor Cyan

# OnpremLgwName (in onprem RG — represents Hub side)
$lgwJson = az network local-gateway show -g $OnpremResourceGroup -n $OnpremLgwName `
    --query '{state:provisioningState, gwIp:gatewayIpAddress, prefixes:localNetworkAddressSpace.addressPrefixes}' `
    -o json 2>$null
if ($lgwJson) {
    $lgw = $lgwJson | ConvertFrom-Json
    Test-Val "$OnpremLgwName プロビジョニング" $lgw.state 'Succeeded'
    if ($hubPip) {
        Test-Val "$OnpremLgwName -> Hub PIP 一致" $lgw.gwIp $hubPip
    } else {
        Test-NotEmpty "$OnpremLgwName Gateway IP" $lgw.gwIp
    }
    $expectedPrefixes = @('10.10.0.0/16', '10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16')
    $actualPrefixes = @($lgw.prefixes | Sort-Object)
    $expectedSorted = @($expectedPrefixes | Sort-Object)
    $prefixMatch = ($actualPrefixes -join ',') -eq ($expectedSorted -join ',')
    Test-Bool "$OnpremLgwName アドレス空間 (Hub + Spoke1-4: $($actualPrefixes -join ', '))" $prefixMatch
} else {
    Test-Val $OnpremLgwName '(未検出)' 'Succeeded'
}

# HubLgwName (in Hub RG — represents OnPrem side)
$lgwOnpremJson = az network local-gateway show -g $HubResourceGroup -n $HubLgwName `
    --query '{state:provisioningState, gwIp:gatewayIpAddress, prefixes:localNetworkAddressSpace.addressPrefixes}' `
    -o json 2>$null
if ($lgwOnpremJson) {
    $lgwOnprem = $lgwOnpremJson | ConvertFrom-Json
    Test-Val "$HubLgwName プロビジョニング" $lgwOnprem.state 'Succeeded'
    if ($onpremPip) {
        Test-Val "$HubLgwName -> OnPrem PIP 一致" $lgwOnprem.gwIp $onpremPip
    } else {
        Test-NotEmpty "$HubLgwName Gateway IP" $lgwOnprem.gwIp
    }
    Test-Bool "$HubLgwName アドレス空間: $($lgwOnprem.prefixes -join ', ')" ($lgwOnprem.prefixes.Count -gt 0)
} else {
    Test-Val $HubLgwName '(未検出)' 'Succeeded'
}

# ============================================================
# 5. S2S VPN 接続
# ============================================================
Write-Host "`n=== 5. S2S VPN 接続 ===" -ForegroundColor Cyan

$cnJson = az network vpn-connection show -g $OnpremResourceGroup -n $OnpremConnectionName `
    --query '{state:provisioningState, status:connectionStatus, protocol:connectionProtocol, type:connectionType}' `
    -o json 2>$null
if ($cnJson) {
    $cn = $cnJson | ConvertFrom-Json
    Test-Val "$OnpremConnectionName プロビジョニング" $cn.state    'Succeeded'
    Test-Val "$OnpremConnectionName 接続状態"         $cn.status   'Connected'
    Test-Val "$OnpremConnectionName タイプ"           $cn.type     'IPsec'
    Test-Val "$OnpremConnectionName プロトコル"        $cn.protocol 'IKEv2'
} else {
    Test-Val $OnpremConnectionName '(未検出)' 'Succeeded'
}

$cnHubJson = az network vpn-connection show -g $HubResourceGroup -n $HubConnectionName `
    --query '{state:provisioningState, status:connectionStatus, protocol:connectionProtocol, type:connectionType}' `
    -o json 2>$null
if ($cnHubJson) {
    $cnHub = $cnHubJson | ConvertFrom-Json
    Test-Val "$HubConnectionName プロビジョニング" $cnHub.state    'Succeeded'
    Test-Val "$HubConnectionName 接続状態"         $cnHub.status   'Connected'
    Test-Val "$HubConnectionName タイプ"           $cnHub.type     'IPsec'
    Test-Val "$HubConnectionName プロトコル"        $cnHub.protocol 'IKEv2'
} else {
    Test-Val $HubConnectionName '(未検出)' 'Succeeded'
}

# ============================================================
# 6. 接続情報サマリ
# ============================================================
Write-Host "`n=== 6. 接続情報サマリ ===" -ForegroundColor Cyan

Write-Host "  オンプレ VPN GW PIP  : $onpremPip" -ForegroundColor Gray
Write-Host "  Hub VPN GW PIP       : $hubPip" -ForegroundColor Gray
Write-Host "  LGW ($OnpremLgwName)  : $(if ($lgwJson) { ($lgwJson | ConvertFrom-Json).gwIp } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  LGW ($HubLgwName)     : $(if ($lgwOnpremJson) { ($lgwOnpremJson | ConvertFrom-Json).gwIp } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  接続状態 (->Hub)      : $(if ($cnJson) { ($cnJson | ConvertFrom-Json).status } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  接続状態 (<-Hub)      : $(if ($cnHubJson) { ($cnHubJson | ConvertFrom-Json).status } else { '(未検出)' })" -ForegroundColor Gray

# ============================================================
# 7. Hub-Spoke ピアリング Gateway Transit
# ============================================================
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

# ============================================================
# 8. IP 到達性テスト (az vm run-command invoke)
# ============================================================
Write-Host "`n=== 8. IP 到達性テスト ===" -ForegroundColor Cyan

# VPN 接続が未デプロイならスキップ
if (-not $cnJson) {
    Write-Host "  [SKIP] VPN 接続 ($OnpremConnectionName) が未デプロイのためスキップ" -ForegroundColor DarkGray
} else {

Write-Host "  (az vm run-command invoke を使用 — 各テストに 30〜60 秒かかります)" -ForegroundColor DarkGray

# OnPrem VM の Private IP を動的取得
$onpremVmIp = az vm list-ip-addresses -g $OnpremResourceGroup -n $OnpremVmName `
    --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>$null

# Hub DNS Resolver Inbound IP を動的取得
$hubDnsResolverIp = az dns-resolver inbound-endpoint show `
    -g $HubResourceGroup --dns-resolver-name dnspr-hub -n inbound `
    --query 'ipConfigurations[0].privateIpAddress' -o tsv 2>$null
if (-not $hubDnsResolverIp) {
    Write-Host "  [INFO] Hub DNS Resolver が見つかりません。10.10.5.4 をフォールバックとして使用します。" -ForegroundColor DarkGray
    $hubDnsResolverIp = '10.10.5.4'
}

# テスト対象の定義: 送信元 VM -> 宛先 IP:ポート
$connectivityTests = @(
    @{ srcRg = $OnpremResourceGroup; srcVm = $OnpremVmName; dstIp = $hubDnsResolverIp; port = 53; label = "OnPrem ($OnpremVmName) -> Hub (DNS Resolver ${hubDnsResolverIp}:53)" }
)

# Spoke1 Web VM が存在すれば双方向テスト (RDP:3389)
$spoke1WebVm = az vm show -g rg-spoke1 -n vm-spoke1-web --query 'name' -o tsv 2>$null
if ($spoke1WebVm -and $onpremVmIp) {
    $spoke1Ip = az vm list-ip-addresses -g rg-spoke1 -n vm-spoke1-web `
        --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>$null
    if ($spoke1Ip) {
        $connectivityTests += @{ srcRg = $OnpremResourceGroup; srcVm = $OnpremVmName; dstIp = $spoke1Ip; port = 3389; label = "OnPrem ($OnpremVmName) -> Spoke1 (vm-spoke1-web ${spoke1Ip}:3389)" }
        $connectivityTests += @{ srcRg = 'rg-spoke1'; srcVm = 'vm-spoke1-web'; dstIp = $onpremVmIp; port = 3389; label = "Spoke1 (vm-spoke1-web) -> OnPrem ($OnpremVmName ${onpremVmIp}:3389)" }
    }
} else {
    Write-Host "  [SKIP] OnPrem <-> Spoke1 — vm-spoke1-web が未デプロイ" -ForegroundColor DarkGray
}

foreach ($test in $connectivityTests) {
    # 送信元 VM の存在確認
    $vmExists = az vm show -g $test.srcRg -n $test.srcVm --query "name" -o tsv 2>$null
    if (-not $vmExists) {
        Write-Host "  [SKIP] $($test.label) — 送信元 VM が未デプロイ" -ForegroundColor DarkGray
        continue
    }

    Write-Host "  リモートコマンド実行中: $($test.label)..." -ForegroundColor Gray
    $pingScript = "Test-NetConnection -ComputerName '$($test.dstIp)' -Port $($test.port) -WarningAction SilentlyContinue | Select-Object -ExpandProperty TcpTestSucceeded"
    $result = az vm run-command invoke `
        --resource-group $test.srcRg `
        --name $test.srcVm `
        --command-id RunPowerShellScript `
        --scripts $pingScript `
        --query "value[0].message" -o tsv 2>$null

    $reachable = ($result | Out-String) -match 'True'
    Test-Bool $test.label $reachable
}

} # end VPN 接続スキップガード

# ============================================================
# 9. Spoke VM 動的検出 + 双方向到達性テスト (-TestSpokeReachability)
# ============================================================

# VPN 接続が未デプロイならスキップ
if (-not $cnJson) {
    if ($TestSpokeReachability) {
        Write-Host "`n=== 9. Spoke VM 動的検出 + 双方向到達性テスト ===" -ForegroundColor Cyan
        Write-Host "  [SKIP] VPN 接続 ($OnpremConnectionName) が未デプロイのためスキップ" -ForegroundColor DarkGray
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
        # Spoke RG 内の VM 一覧を取得
        $vmsJson = az vm list -g $spoke.rg `
            --query "[].{name:name, nicId:networkProfile.networkInterfaces[0].id}" `
            -o json 2>$null
        if (-not $vmsJson -or $vmsJson -eq '[]') {
            Write-Host "  [$($spoke.label)] VM なし — スキップ" -ForegroundColor DarkGray
            continue
        }
        $vms = $vmsJson | ConvertFrom-Json
        foreach ($vm in $vms) {
            # NIC から Private IP を取得
            $privateIp = az network nic show --ids $vm.nicId `
                --query "ipConfigurations[0].privateIPAddress" -o tsv 2>$null
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
            # OnPrem (DC01) -> Spoke VM
            $fwdLabel = "OnPrem ($OnpremVmName) -> $($vm.label) ($($vm.name) $($vm.ip))"
            Write-Host "  リモートコマンド実行中: $fwdLabel..." -ForegroundColor Gray
            $fwdScript = "Test-NetConnection -ComputerName '$($vm.ip)' -Port 3389 -WarningAction SilentlyContinue | Select-Object -ExpandProperty TcpTestSucceeded"
            $fwdResult = az vm run-command invoke `
                --resource-group $OnpremResourceGroup `
                --name $OnpremVmName `
                --command-id RunPowerShellScript `
                --scripts $fwdScript `
                --query 'value[0].message' -o tsv 2>$null
            Test-Bool $fwdLabel (($fwdResult | Out-String) -match 'True')

            # Spoke VM -> OnPrem
            $revLabel = "$($vm.label) ($($vm.name)) -> OnPrem ($OnpremVmName $onpremVmIp)"
            Write-Host "  リモートコマンド実行中: $revLabel..." -ForegroundColor Gray
            $revScript = "Test-NetConnection -ComputerName '$onpremVmIp' -Port 3389 -WarningAction SilentlyContinue | Select-Object -ExpandProperty TcpTestSucceeded"
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

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}
