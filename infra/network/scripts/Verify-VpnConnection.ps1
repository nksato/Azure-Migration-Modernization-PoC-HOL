<#
.SYNOPSIS
    VPN Gateway 配置・接続の状態を検証する
.DESCRIPTION
    Azure CLI でオンプレ側・Hub 側の VPN Gateway、S2S 接続、
    ピアリングの Gateway Transit 設定を確認する。
    Azure API のみで完結する簡易チェック。
.EXAMPLE
    .\Verify-VpnConnection.ps1
#>

[CmdletBinding()]
param()

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

$onpremGwSnet = az network vnet subnet show -g rg-onprem --vnet-name vnet-onprem -n GatewaySubnet `
    --query "addressPrefix" -o tsv 2>$null
Test-NotEmpty 'vnet-onprem/GatewaySubnet' $onpremGwSnet

$hubGwSnet = az network vnet subnet show -g rg-hub --vnet-name vnet-hub -n GatewaySubnet `
    --query "addressPrefix" -o tsv 2>$null
Test-NotEmpty 'vnet-hub/GatewaySubnet' $hubGwSnet

# ============================================================
# 2. VPN Gateway (オンプレ側)
# ============================================================
Write-Host "`n=== 2. VPN Gateway (オンプレ側) ===" -ForegroundColor Cyan

$onpremGwJson = az network vnet-gateway show -g rg-onprem -n vgw-onprem `
    --query "{state:provisioningState, sku:sku.name, vpnType:vpnType}" -o json 2>$null
if ($onpremGwJson) {
    $onpremGw = $onpremGwJson | ConvertFrom-Json
    Test-Val  'vgw-onprem プロビジョニング' $onpremGw.state   'Succeeded'
    Test-Val  'vgw-onprem SKU'              $onpremGw.sku     'VpnGw1AZ'
    Test-Val  'vgw-onprem VPN タイプ'        $onpremGw.vpnType 'RouteBased'
} else {
    Test-Val 'vgw-onprem' '(未検出)' 'Succeeded'
}

$onpremPip = az network public-ip show -g rg-onprem -n vgw-onprem-pip1 `
    --query "ipAddress" -o tsv 2>$null
Test-NotEmpty 'vgw-onprem Public IP' $onpremPip

# ============================================================
# 3. VPN Gateway (Hub 側)
# ============================================================
Write-Host "`n=== 3. VPN Gateway (Hub 側) ===" -ForegroundColor Cyan

$hubGwJson = az network vnet-gateway show -g rg-hub -n vpngw-hub `
    --query "{state:provisioningState, sku:sku.name, vpnType:vpnType}" -o json 2>$null
if ($hubGwJson) {
    $hubGw = $hubGwJson | ConvertFrom-Json
    Test-Val  'vpngw-hub プロビジョニング' $hubGw.state   'Succeeded'
    Test-Val  'vpngw-hub SKU'              $hubGw.sku     'VpnGw1AZ'
    Test-Val  'vpngw-hub VPN タイプ'        $hubGw.vpnType 'RouteBased'
} else {
    Test-Val 'vpngw-hub' '(未検出)' 'Succeeded'
}

$hubPip = az network public-ip show -g rg-hub -n vpngw-hub-pip1 `
    --query "ipAddress" -o tsv 2>$null
Test-NotEmpty 'vpngw-hub Public IP' $hubPip

# ============================================================
# 4. Local Network Gateway
# ============================================================
Write-Host "`n=== 4. Local Network Gateway ===" -ForegroundColor Cyan

$lgwJson = az network local-gateway show -g rg-onprem -n lgw-hub `
    --query "{state:provisioningState, gwIp:gatewayIpAddress, prefixes:localNetworkAddressSpace.addressPrefixes}" `
    -o json 2>$null
if ($lgwJson) {
    $lgw = $lgwJson | ConvertFrom-Json
    Test-Val 'lgw-hub プロビジョニング' $lgw.state 'Succeeded'
    # LGW の gatewayIpAddress が Hub VPN Gateway の PIP と一致するか
    if ($hubPip) {
        Test-Val 'lgw-hub → Hub PIP 一致' $lgw.gwIp $hubPip
    } else {
        Test-NotEmpty 'lgw-hub Gateway IP' $lgw.gwIp
    }
    # アドレス空間: Hub + Spoke1-4 の 5 プレフィックスを検証
    $expectedPrefixes = @('10.10.0.0/16', '10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16')
    $actualPrefixes = @($lgw.prefixes | Sort-Object)
    $expectedSorted = @($expectedPrefixes | Sort-Object)
    $prefixMatch = ($actualPrefixes -join ',') -eq ($expectedSorted -join ',')
    Test-Bool "lgw-hub アドレス空間 (Hub + Spoke1-4: $($actualPrefixes -join ', '))" $prefixMatch
} else {
    Test-Val 'lgw-hub' '(未検出)' 'Succeeded'
}

# ============================================================
# 5. S2S VPN 接続
# ============================================================
Write-Host "`n=== 5. S2S VPN 接続 ===" -ForegroundColor Cyan

$cnJson = az network vpn-connection show -g rg-onprem -n cn-onprem-to-hub `
    --query "{state:provisioningState, status:connectionStatus, protocol:connectionProtocol}" `
    -o json 2>$null
if ($cnJson) {
    $cn = $cnJson | ConvertFrom-Json
    Test-Val 'cn-onprem-to-hub プロビジョニング' $cn.state    'Succeeded'
    Test-Val 'cn-onprem-to-hub 接続状態'         $cn.status   'Connected'
    Test-Val 'cn-onprem-to-hub プロトコル'        $cn.protocol 'IKEv2'
} else {
    Test-Val 'cn-onprem-to-hub' '(未検出)' 'Succeeded'
}

# ============================================================
# 6. 接続情報サマリ
# ============================================================
Write-Host "`n=== 6. 接続情報サマリ ===" -ForegroundColor Cyan

Write-Host "  オンプレ VPN GW PIP  : $onpremPip" -ForegroundColor Gray
Write-Host "  Hub VPN GW PIP       : $hubPip" -ForegroundColor Gray
Write-Host "  LGW → Hub IP         : $(if ($lgwJson) { ($lgwJson | ConvertFrom-Json).gwIp } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  LGW アドレス空間     : $(if ($lgwJson) { ($lgwJson | ConvertFrom-Json).prefixes -join ', ' } else { '(未検出)' })" -ForegroundColor Gray
Write-Host "  接続状態             : $(if ($cnJson) { ($cnJson | ConvertFrom-Json).status } else { '(未検出)' })" -ForegroundColor Gray

# ============================================================
# 7. Hub-Spoke ピアリング Gateway Transit
# ============================================================
Write-Host "`n=== 7. Hub-Spoke ピアリング Gateway Transit ===" -ForegroundColor Cyan

# Hub 側: allowGatewayTransit = true
$hubPeerings = az network vnet peering list -g rg-hub --vnet-name vnet-hub `
    --query "[].{name:name, gwTransit:allowGatewayTransit, state:peeringState}" -o json 2>$null | ConvertFrom-Json

foreach ($spoke in @('vnet-spoke1', 'vnet-spoke2', 'vnet-spoke3', 'vnet-spoke4')) {
    $p = $hubPeerings | Where-Object { $_.name -match $spoke }
    if ($p) {
        Test-Bool "Hub → $spoke allowGatewayTransit" $p.gwTransit
        Test-Val  "Hub → $spoke peeringState"        $p.state 'Connected'
    } else {
        Test-Val "Hub → $spoke" '(未検出)' 'Connected'
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
    Test-Val "$($item.vnet) → Hub useRemoteGateways" $sp 'true'
}

# ============================================================
# 8. IP 到達性テスト (az vm run-command invoke)
# ============================================================
Write-Host "`n=== 8. IP 到達性テスト ===" -ForegroundColor Cyan
Write-Host "  (az vm run-command invoke を使用 — 各テストに 30〜60 秒かかります)" -ForegroundColor DarkGray

# OnPrem DC01 の IP
$onpremDcIp = '10.0.1.4'

# テスト対象の定義: 送信元 VM → 宛先 IP
$connectivityTests = @(
    # OnPrem → Hub (DNS Resolver Inbound as representative)
    @{ srcRg = 'rg-onprem'; srcVm = 'vm-onprem-ad'; dstIp = '10.10.5.4'; label = 'OnPrem (DC01) → Hub (DNS Resolver 10.10.5.4)' }
    # OnPrem → Spoke1 Web VM
    @{ srcRg = 'rg-onprem'; srcVm = 'vm-onprem-ad'; dstIp = '10.20.1.4'; label = 'OnPrem (DC01) → Spoke1 (10.20.1.4)' }
)

# Spoke1 Web VM が存在すれば逆方向もテスト
$spoke1WebVm = az vm show -g rg-spoke1 -n vm-spoke1-web --query "name" -o tsv 2>$null
if ($spoke1WebVm) {
    $connectivityTests += @{ srcRg = 'rg-spoke1'; srcVm = 'vm-spoke1-web'; dstIp = $onpremDcIp; label = 'Spoke1 (vm-spoke1-web) → OnPrem (DC01 10.0.1.4)' }
}

foreach ($test in $connectivityTests) {
    # 送信元 VM の存在確認
    $vmExists = az vm show -g $test.srcRg -n $test.srcVm --query "name" -o tsv 2>$null
    if (-not $vmExists) {
        Write-Host "  [SKIP] $($test.label) — 送信元 VM が未デプロイ" -ForegroundColor DarkGray
        continue
    }

    Write-Host "  リモートコマンド実行中: $($test.label)..." -ForegroundColor Gray
    $pingScript = "Test-NetConnection -ComputerName '$($test.dstIp)' -Port 3389 -WarningAction SilentlyContinue | Select-Object -ExpandProperty TcpTestSucceeded"
    $result = az vm run-command invoke `
        --resource-group $test.srcRg `
        --name $test.srcVm `
        --command-id RunPowerShellScript `
        --scripts $pingScript `
        --query "value[0].message" -o tsv 2>$null

    $reachable = $result -match 'True'
    Test-Bool $test.label $reachable
}

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}
