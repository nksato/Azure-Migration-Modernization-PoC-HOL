<#
.SYNOPSIS
    クラウド基盤 (Hub & Spoke) のデプロイ状態を検証する
.DESCRIPTION
    Azure CLI でリソースの存在・状態を確認する。
    VM 内部には入らず、Azure API だけで完結する簡易チェック。
    ブラウザでのポータル画面確認は含まない。
.EXAMPLE
    .\Verify-CloudDeploy.ps1
    .\Verify-CloudDeploy.ps1 -SkipFirewall -SkipBastion
#>

[CmdletBinding()]
param(
    [switch]$SkipFirewall,
    [switch]$SkipBastion
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
# 1. リソースグループ
# ============================================================
Write-Host "`n=== 1. リソースグループ ===" -ForegroundColor Cyan

foreach ($rg in @('rg-hub', 'rg-spoke1', 'rg-spoke2', 'rg-spoke3', 'rg-spoke4')) {
    $exists = az group exists -n $rg -o tsv 2>$null
    Test-Val $rg $exists 'true'
}

# ============================================================
# 2. VNet & アドレス空間
# ============================================================
Write-Host "`n=== 2. VNet & アドレス空間 ===" -ForegroundColor Cyan

$vnets = @{
    'vnet-hub'    = @{ rg = 'rg-hub';    cidr = '10.10.0.0/16' }
    'vnet-spoke1' = @{ rg = 'rg-spoke1'; cidr = '10.20.0.0/16' }
    'vnet-spoke2' = @{ rg = 'rg-spoke2'; cidr = '10.21.0.0/16' }
    'vnet-spoke3' = @{ rg = 'rg-spoke3'; cidr = '10.22.0.0/16' }
    'vnet-spoke4' = @{ rg = 'rg-spoke4'; cidr = '10.23.0.0/16' }
}

foreach ($vnet in $vnets.GetEnumerator()) {
    $addr = az network vnet show -g $vnet.Value.rg -n $vnet.Key `
        --query "addressSpace.addressPrefixes[0]" -o tsv 2>$null
    Test-Val $vnet.Key $addr $vnet.Value.cidr
}

# ============================================================
# 3. Hub サブネット
# ============================================================
Write-Host "`n=== 3. Hub サブネット ===" -ForegroundColor Cyan

$hubSubnets = @(
    'AzureFirewallSubnet'
    'AzureFirewallManagementSubnet'
    'AzureBastionSubnet'
    'GatewaySubnet'
    'snet-dns-inbound'
    'snet-dns-outbound'
)

foreach ($snet in $hubSubnets) {
    $prefix = az network vnet subnet show -g rg-hub --vnet-name vnet-hub -n $snet `
        --query "addressPrefix" -o tsv 2>$null
    Test-NotEmpty "vnet-hub/$snet" $prefix
}

# ============================================================
# 4. Spoke サブネット
# ============================================================
Write-Host "`n=== 4. Spoke サブネット ===" -ForegroundColor Cyan

$spokeSubnets = @{
    'vnet-spoke1' = @{ rg = 'rg-spoke1'; subnets = @('snet-web', 'snet-db') }
    'vnet-spoke2' = @{ rg = 'rg-spoke2'; subnets = @('snet-web', 'snet-pep') }
    'vnet-spoke3' = @{ rg = 'rg-spoke3'; subnets = @('snet-aca', 'snet-pep') }
    'vnet-spoke4' = @{ rg = 'rg-spoke4'; subnets = @('snet-appservice', 'snet-pep') }
}

foreach ($spoke in $spokeSubnets.GetEnumerator()) {
    foreach ($snet in $spoke.Value.subnets) {
        $prefix = az network vnet subnet show -g $spoke.Value.rg --vnet-name $spoke.Key -n $snet `
            --query "addressPrefix" -o tsv 2>$null
        Test-NotEmpty "$($spoke.Key)/$snet" $prefix
    }
}

# ============================================================
# 5. VNet ピアリング (Hub → Spoke)
# ============================================================
Write-Host "`n=== 5. VNet ピアリング ===" -ForegroundColor Cyan

$peerings = az network vnet peering list -g rg-hub --vnet-name vnet-hub `
    --query "[].{name:name, state:peeringState}" -o json 2>$null | ConvertFrom-Json

foreach ($spoke in @('vnet-spoke1', 'vnet-spoke2', 'vnet-spoke3', 'vnet-spoke4')) {
    $p = $peerings | Where-Object { $_.name -match $spoke }
    if ($p) {
        Test-Val "Hub → $spoke" $p.state 'Connected'
    } else {
        Test-Val "Hub → $spoke" '(未検出)' 'Connected'
    }
}

# ============================================================
# 6. Azure Firewall
# ============================================================
if (-not $SkipFirewall) {
    Write-Host "`n=== 6. Azure Firewall ===" -ForegroundColor Cyan

    $fwState = az network firewall show -g rg-hub -n afw-hub `
        --query "provisioningState" -o tsv 2>$null
    Test-Val 'afw-hub プロビジョニング' $fwState 'Succeeded'

    $fwPolicy = az network firewall policy show -g rg-hub -n afwp-hub `
        --query "provisioningState" -o tsv 2>$null
    Test-Val 'afwp-hub ポリシー' $fwPolicy 'Succeeded'

    $rt = az network route-table show -g rg-hub -n rt-spokes-to-fw `
        --query "provisioningState" -o tsv 2>$null
    Test-Val 'rt-spokes-to-fw ルートテーブル' $rt 'Succeeded'

    $rtGw = az network route-table show -g rg-hub -n rt-gateway-to-fw `
        --query "provisioningState" -o tsv 2>$null
    Test-Val 'rt-gateway-to-fw ルートテーブル' $rtGw 'Succeeded'
} else {
    Write-Host "`n=== 6. Azure Firewall (スキップ) ===" -ForegroundColor DarkGray
}

# ============================================================
# 6.5 接続ルール (Firewall ネットワークルール)
# ============================================================
Write-Host "`n=== 6.5 接続ルール (Firewall ネットワークルール) ===" -ForegroundColor Cyan

if (-not $SkipFirewall) {
    # Firewall Policy からネットワークルールを取得
    $ruleCollections = az network firewall policy rule-collection-group show `
        -g rg-hub --policy-name afwp-hub --name DefaultNetworkRuleCollectionGroup `
        --query "ruleCollections[0].rules[].name" -o json 2>$null | ConvertFrom-Json

    $ruleNames = if ($ruleCollections) { $ruleCollections } else { @() }

    # 各接続パスの判定
    $onpremToSpoke = 'OnPrem-to-Spokes' -in $ruleNames
    $spokeToOnprem = 'Spokes-to-OnPrem' -in $ruleNames
    $spokeToSpoke  = 'Spoke-to-Spoke'   -in $ruleNames

    # Peering 状態の確認 (Hub↔Spoke)
    $hubPeerings = az network vnet peering list -g rg-hub --vnet-name vnet-hub `
        --query "[].{name:name, state:peeringState}" -o json 2>$null | ConvertFrom-Json
    $allPeeringsConnected = ($hubPeerings | Where-Object { $_.state -eq 'Connected' }).Count -ge 4

    Write-Host "  Peering (Hub ↔ Spoke 全4本): $(if ($allPeeringsConnected) {'Connected'} else {'一部未接続'})" `
        -ForegroundColor $(if ($allPeeringsConnected) {'Green'} else {'Yellow'})

    $directions = @(
        @{ Label = 'OnPrem → Spoke'; Allowed = $onpremToSpoke -and $allPeeringsConnected; Rule = 'OnPrem-to-Spokes' }
        @{ Label = 'Spoke  → OnPrem'; Allowed = $spokeToOnprem -and $allPeeringsConnected; Rule = 'Spokes-to-OnPrem' }
        @{ Label = 'Spoke ↔ Spoke'; Allowed = $spokeToSpoke  -and $allPeeringsConnected; Rule = 'Spoke-to-Spoke' }
    )

    foreach ($d in $directions) {
        $status = if ($d.Allowed) { 'Allow' } else { 'Deny' }
        $reason = if (-not $allPeeringsConnected) {
            '(Peering 未接続)'
        } elseif ($d.Allowed) {
            "(rule: $($d.Rule))"
        } else {
            '(ルール未検出)'
        }
        $color = if ($d.Allowed) { 'Green' } else { 'Yellow' }
        Write-Host ("  {0}: {1} {2}" -f $d.Label, $status, $reason) -ForegroundColor $color
    }
} else {
    Write-Host "  (Firewall スキップのため判定不可)" -ForegroundColor DarkGray
}

# ============================================================
# 7. Azure Bastion
# ============================================================
if (-not $SkipBastion) {
    Write-Host "`n=== 7. Azure Bastion ===" -ForegroundColor Cyan

    $basState = az network bastion show -g rg-hub -n bas-hub `
        --query "provisioningState" -o tsv 2>$null
    Test-Val 'bas-hub プロビジョニング' $basState 'Succeeded'
} else {
    Write-Host "`n=== 7. Azure Bastion (スキップ) ===" -ForegroundColor DarkGray
}

# ============================================================
# 8. DNS Private Resolver & Private DNS Zone
# ============================================================
Write-Host "`n=== 8. DNS Private Resolver & Private DNS Zone ===" -ForegroundColor Cyan

$resolverState = az dns-resolver show -g rg-hub -n dnspr-hub `
    --query "provisioningState" -o tsv 2>$null
Test-Val 'dnspr-hub プロビジョニング' $resolverState 'Succeeded'

$inbound = az dns-resolver inbound-endpoint list -g rg-hub --dns-resolver-name dnspr-hub `
    --query "[0].provisioningState" -o tsv 2>$null
Test-Val 'Inbound Endpoint' $inbound 'Succeeded'

$outbound = az dns-resolver outbound-endpoint list -g rg-hub --dns-resolver-name dnspr-hub `
    --query "[0].provisioningState" -o tsv 2>$null
Test-Val 'Outbound Endpoint' $outbound 'Succeeded'

$pdnsz = az network private-dns zone show -g rg-hub -n privatelink.database.windows.net `
    --query "name" -o tsv 2>$null
Test-Val 'Private DNS Zone' $pdnsz 'privatelink.database.windows.net'

# VNet リンク数の確認 (hub + spoke2/3/4 = 4)
$links = az network private-dns link vnet list -g rg-hub -z privatelink.database.windows.net `
    -o json 2>$null | ConvertFrom-Json
$linkCount = if ($links) { $links.Count } else { 0 }
Test-Bool "Private DNS Zone VNet リンク数 >= 4 (実際: $linkCount)" ($linkCount -ge 4)

# ============================================================
# 9. Log Analytics Workspace
# ============================================================
Write-Host "`n=== 9. Log Analytics Workspace ===" -ForegroundColor Cyan

$lawState = az monitor log-analytics workspace show -g rg-hub -n log-hub `
    --query "provisioningState" -o tsv 2>$null
Test-Val 'log-hub プロビジョニング' $lawState 'Succeeded'

# ============================================================
# 10. ポリシー割り当て
# ============================================================
Write-Host "`n=== 10. ポリシー割り当て ===" -ForegroundColor Cyan

$policyNames = @(
    'policy-allowed-locations'
    'policy-storage-no-public'
    'policy-sql-auditing'
    'policy-sql-no-public'
    'policy-require-env-tag'
    'policy-mgmt-ports-audit'
    'policy-appservice-no-public'
)

$assignments = az policy assignment list --query "[].name" -o json 2>$null | ConvertFrom-Json

foreach ($pn in $policyNames) {
    $found = $pn -in $assignments
    Test-Bool "ポリシー: $pn" $found
}

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}
