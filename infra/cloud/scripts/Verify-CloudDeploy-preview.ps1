<#
.SYNOPSIS
    [PREVIEW] クラウド基盤 (Hub & Spoke) のデプロイ状態を検証する
.DESCRIPTION
    Verify-CloudDeploy.ps1 のテスト版。
    追加機能:
      -Detail     : Firewall ルール・ルートテーブル・ポリシー等の設定値を詳細表示
      -OutputPath : 検証結果を JSON ファイルに保存

    ※ このファイルは preview 版です。安定したら Verify-CloudDeploy.ps1 に統合します。

    Azure CLI でリソースの存在・状態を確認する。
    VM 内部には入らず、Azure API だけで完結する簡易チェック。
.EXAMPLE
    .\Verify-CloudDeploy-preview.ps1
    .\Verify-CloudDeploy-preview.ps1 -Detail
    .\Verify-CloudDeploy-preview.ps1 -Detail -OutputPath .\cloud-verify-result.json
    .\Verify-CloudDeploy-preview.ps1 -SkipFirewall -SkipBastion
#>

[CmdletBinding()]
param(
    [switch]$SkipFirewall,
    [switch]$SkipBastion,
    [switch]$Detail,
    [string]$OutputPath
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# --- 結果収集用 ---
$script:results = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- ヘルパー ---

function Add-Result ([string]$Section, [string]$Label, [string]$Status, [string]$Actual, [string]$Expected, $DetailData) {
    $script:results.Add([PSCustomObject]@{
        Section  = $Section
        Label    = $Label
        Status   = $Status
        Actual   = $Actual
        Expected = $Expected
        Detail   = $DetailData
    })
}

function Test-Val ([string]$Section, [string]$Label, [string]$Actual, [string]$Expected, $DetailData = $null) {
    $ok = $Actual -eq $Expected
    $status = if ($ok) { 'PASS' } else { 'FAIL' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: {2}" -f $status, $Label, $Actual) -ForegroundColor $color
    Add-Result $Section $Label $status $Actual $Expected $DetailData
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-NotEmpty ([string]$Section, [string]$Label, [string]$Actual, $DetailData = $null) {
    $ok = -not [string]::IsNullOrWhiteSpace($Actual)
    $status = if ($ok) { 'PASS' } else { 'FAIL' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    $display = if ($ok) { $Actual } else { '(未検出)' }
    Write-Host ("  [{0}] {1}: {2}" -f $status, $Label, $display) -ForegroundColor $color
    Add-Result $Section $Label $status $display '' $DetailData
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-Bool ([string]$Section, [string]$Label, [bool]$Value, $DetailData = $null) {
    $status = if ($Value) { 'PASS' } else { 'FAIL' }
    $color = if ($Value) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $status, $Label) -ForegroundColor $color
    Add-Result $Section $Label $status "$Value" 'True' $DetailData
    $script:total++; if ($Value) { $script:passed++ }
}

function Write-Detail ([string]$Text) {
    if ($Detail) {
        Write-Host "        $Text" -ForegroundColor DarkGray
    }
}

# ============================================================
# 1. リソースグループ
# ============================================================
$sectionName = '1. リソースグループ'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

foreach ($rg in @('rg-hub', 'rg-spoke1', 'rg-spoke2', 'rg-spoke3', 'rg-spoke4')) {
    $exists = az group exists -n $rg -o tsv 2>$null
    $detailData = $null
    if ($Detail -and $exists -eq 'true') {
        $rgInfo = az group show -n $rg -o json 2>$null | ConvertFrom-Json
        $detailData = @{
            location = $rgInfo.location
            tags     = $rgInfo.tags
        }
    }
    Test-Val $sectionName $rg $exists 'true' $detailData
    if ($detailData) {
        Write-Detail "location: $($detailData.location)"
        $tagStr = ($detailData.tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
        Write-Detail "tags: $tagStr"
    }
}

# ============================================================
# 2. VNet & アドレス空間
# ============================================================
$sectionName = '2. VNet & アドレス空間'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

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
    $detailData = $null
    if ($Detail -and $addr) {
        $vnetJson = az network vnet show -g $vnet.Value.rg -n $vnet.Key -o json 2>$null | ConvertFrom-Json
        $subnetNames = ($vnetJson.subnets | ForEach-Object { "$($_.name) ($($_.addressPrefix))" }) -join ', '
        $detailData = @{
            subnets        = $vnetJson.subnets | ForEach-Object { @{ name = $_.name; addressPrefix = $_.addressPrefix } }
            dnsServers     = $vnetJson.dhcpOptions.dnsServers
            enableDdos     = $vnetJson.enableDdosProtection
        }
    }
    Test-Val $sectionName $vnet.Key $addr $vnet.Value.cidr $detailData
    if ($detailData) {
        Write-Detail "subnets: $subnetNames"
        if ($detailData.dnsServers) {
            Write-Detail "dnsServers: $($detailData.dnsServers -join ', ')"
        }
    }
}

# ============================================================
# 3. Hub サブネット
# ============================================================
$sectionName = '3. Hub サブネット'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

$hubSubnets = @(
    'AzureFirewallSubnet'
    'AzureFirewallManagementSubnet'
    'AzureBastionSubnet'
    'GatewaySubnet'
    'snet-dns-inbound'
    'snet-dns-outbound'
)

foreach ($snet in $hubSubnets) {
    $detailData = $null
    if ($Detail) {
        $subnetJson = az network vnet subnet show -g rg-hub --vnet-name vnet-hub -n $snet -o json 2>$null | ConvertFrom-Json
        if ($subnetJson) {
            $detailData = @{
                addressPrefix = $subnetJson.addressPrefix
                nsg           = if ($subnetJson.networkSecurityGroup) { $subnetJson.networkSecurityGroup.id.Split('/')[-1] } else { $null }
                routeTable    = if ($subnetJson.routeTable) { $subnetJson.routeTable.id.Split('/')[-1] } else { $null }
            }
        }
        $prefix = $subnetJson.addressPrefix
    } else {
        $prefix = az network vnet subnet show -g rg-hub --vnet-name vnet-hub -n $snet `
            --query "addressPrefix" -o tsv 2>$null
    }
    Test-NotEmpty $sectionName "vnet-hub/$snet" $prefix $detailData
    if ($detailData) {
        if ($detailData.nsg) { Write-Detail "NSG: $($detailData.nsg)" }
        if ($detailData.routeTable) { Write-Detail "RouteTable: $($detailData.routeTable)" }
    }
}

# ============================================================
# 4. Spoke サブネット
# ============================================================
$sectionName = '4. Spoke サブネット'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

$spokeSubnets = @{
    'vnet-spoke1' = @{ rg = 'rg-spoke1'; subnets = @('snet-web', 'snet-db') }
    'vnet-spoke2' = @{ rg = 'rg-spoke2'; subnets = @('snet-web', 'snet-pep') }
    'vnet-spoke3' = @{ rg = 'rg-spoke3'; subnets = @('snet-aca', 'snet-pep') }
    'vnet-spoke4' = @{ rg = 'rg-spoke4'; subnets = @('snet-appservice', 'snet-pep') }
}

foreach ($spoke in $spokeSubnets.GetEnumerator()) {
    foreach ($snet in $spoke.Value.subnets) {
        $detailData = $null
        if ($Detail) {
            $subnetJson = az network vnet subnet show -g $spoke.Value.rg --vnet-name $spoke.Key -n $snet -o json 2>$null | ConvertFrom-Json
            if ($subnetJson) {
                $detailData = @{
                    addressPrefix = $subnetJson.addressPrefix
                    nsg           = if ($subnetJson.networkSecurityGroup) { $subnetJson.networkSecurityGroup.id.Split('/')[-1] } else { $null }
                    routeTable    = if ($subnetJson.routeTable) { $subnetJson.routeTable.id.Split('/')[-1] } else { $null }
                    delegations   = $subnetJson.delegations | ForEach-Object { $_.serviceName }
                }
            }
            $prefix = $subnetJson.addressPrefix
        } else {
            $prefix = az network vnet subnet show -g $spoke.Value.rg --vnet-name $spoke.Key -n $snet `
                --query "addressPrefix" -o tsv 2>$null
        }
        Test-NotEmpty $sectionName "$($spoke.Key)/$snet" $prefix $detailData
        if ($detailData) {
            if ($detailData.routeTable) { Write-Detail "RouteTable: $($detailData.routeTable)" }
            if ($detailData.delegations) { Write-Detail "Delegation: $($detailData.delegations -join ', ')" }
        }
    }
}

# ============================================================
# 5. VNet ピアリング (Hub → Spoke)
# ============================================================
$sectionName = '5. VNet ピアリング'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

$peeringQuery = if ($Detail) { "[].{name:name, state:peeringState, allowForwardedTraffic:allowForwardedTraffic, allowGatewayTransit:allowGatewayTransit, useRemoteGateways:useRemoteGateways}" } else { "[].{name:name, state:peeringState}" }
$peerings = az network vnet peering list -g rg-hub --vnet-name vnet-hub `
    --query $peeringQuery -o json 2>$null | ConvertFrom-Json

foreach ($spoke in @('vnet-spoke1', 'vnet-spoke2', 'vnet-spoke3', 'vnet-spoke4')) {
    $p = $peerings | Where-Object { $_.name -match $spoke }
    $detailData = $null
    if ($p) {
        if ($Detail) {
            $detailData = @{
                allowForwardedTraffic = $p.allowForwardedTraffic
                allowGatewayTransit   = $p.allowGatewayTransit
                useRemoteGateways     = $p.useRemoteGateways
            }
        }
        Test-Val $sectionName "Hub → $spoke" $p.state 'Connected' $detailData
        if ($detailData) {
            Write-Detail "allowForwardedTraffic: $($p.allowForwardedTraffic), allowGatewayTransit: $($p.allowGatewayTransit), useRemoteGateways: $($p.useRemoteGateways)"
        }
    } else {
        Test-Val $sectionName "Hub → $spoke" '(未検出)' 'Connected'
    }
}

# ============================================================
# 6. Azure Firewall
# ============================================================
$sectionName = '6. Azure Firewall'
if (-not $SkipFirewall) {
    Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

    $fwState = az network firewall show -g rg-hub -n afw-hub `
        --query "provisioningState" -o tsv 2>$null
    $fwDetail = $null
    if ($Detail -and $fwState -eq 'Succeeded') {
        $fwJson = az network firewall show -g rg-hub -n afw-hub -o json 2>$null | ConvertFrom-Json
        $fwDetail = @{
            sku        = $fwJson.sku.tier
            privateIp  = $fwJson.ipConfigurations[0].privateIPAddress
            threatMode = $fwJson.threatIntelMode
        }
    }
    Test-Val $sectionName 'afw-hub プロビジョニング' $fwState 'Succeeded' $fwDetail
    if ($fwDetail) {
        Write-Detail "SKU: $($fwDetail.sku), PrivateIP: $($fwDetail.privateIp)"
    }

    $fwPolicy = az network firewall policy show -g rg-hub -n afwp-hub `
        --query "provisioningState" -o tsv 2>$null
    Test-Val $sectionName 'afwp-hub ポリシー' $fwPolicy 'Succeeded'

    # --- ルートテーブル ---
    foreach ($rtInfo in @(
        @{ name = 'rt-spokes-to-fw'; label = 'rt-spokes-to-fw ルートテーブル' },
        @{ name = 'rt-gateway-to-fw'; label = 'rt-gateway-to-fw ルートテーブル' }
    )) {
        $rtState = az network route-table show -g rg-hub -n $rtInfo.name `
            --query "provisioningState" -o tsv 2>$null
        $rtDetail = $null
        if ($Detail -and $rtState -eq 'Succeeded') {
            $rtJson = az network route-table show -g rg-hub -n $rtInfo.name -o json 2>$null | ConvertFrom-Json
            $routes = $rtJson.routes | ForEach-Object {
                @{ name = $_.name; prefix = $_.addressPrefix; nextHop = $_.nextHopType; nextHopIp = $_.nextHopIpAddress }
            }
            $rtDetail = @{ routes = $routes; disableBgpPropagation = $rtJson.disableBgpRoutePropagation }
        }
        Test-Val $sectionName $rtInfo.label $rtState 'Succeeded' $rtDetail
        if ($rtDetail) {
            foreach ($r in $rtDetail.routes) {
                Write-Detail "$($r.name): $($r.prefix) → $($r.nextHop) ($($r.nextHopIp))"
            }
        }
    }
} else {
    Write-Host "`n=== 6. Azure Firewall (スキップ) ===" -ForegroundColor DarkGray
}

# ============================================================
# 6.5 接続ルール (Firewall ネットワークルール)
# ============================================================
$sectionName = '6.5 接続ルール'
Write-Host "`n=== $sectionName (Firewall ネットワークルール) ===" -ForegroundColor Cyan

if (-not $SkipFirewall) {
    $ruleGroupJson = az network firewall policy rule-collection-group show `
        -g rg-hub --policy-name afwp-hub --name DefaultNetworkRuleCollectionGroup `
        -o json 2>$null | ConvertFrom-Json

    $networkRules = if ($ruleGroupJson) { $ruleGroupJson.ruleCollections[0].rules } else { @() }
    $ruleNames = $networkRules | ForEach-Object { $_.name }

    $onpremToSpoke = 'OnPrem-to-Spokes' -in $ruleNames
    $spokeToOnprem = 'Spokes-to-OnPrem' -in $ruleNames
    $spokeToSpoke  = 'Spoke-to-Spoke'   -in $ruleNames

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
        Add-Result $sectionName $d.Label $status $status '' @{ rule = $d.Rule }
    }

    # -Detail: 全ネットワークルールの詳細表示
    if ($Detail -and $networkRules) {
        Write-Host ""
        Write-Host "  --- ネットワークルール詳細 ---" -ForegroundColor DarkGray
        foreach ($rule in $networkRules) {
            Write-Detail "[$($rule.name)]"
            Write-Detail "  src: $($rule.sourceAddresses -join ', ')"
            Write-Detail "  dst: $($rule.destinationAddresses -join ', ')"
            Write-Detail "  ports: $($rule.destinationPorts -join ', ') / $($rule.ipProtocols -join ', ')"
        }

        # アプリケーションルールも表示
        $appRuleGroupJson = az network firewall policy rule-collection-group show `
            -g rg-hub --policy-name afwp-hub --name DefaultApplicationRuleCollectionGroup `
            -o json 2>$null | ConvertFrom-Json
        if ($appRuleGroupJson) {
            Write-Host ""
            Write-Host "  --- アプリケーションルール詳細 ---" -ForegroundColor DarkGray
            foreach ($rc in $appRuleGroupJson.ruleCollections) {
                Write-Detail "Collection: $($rc.name) (priority: $($rc.priority), action: $($rc.action.type))"
                foreach ($rule in $rc.rules) {
                    $protos = ($rule.protocols | ForEach-Object { "$($_.protocolType):$($_.port)" }) -join ', '
                    $fqdns = $rule.targetFqdns -join ', '
                    Write-Detail "  [$($rule.name)] src=$($rule.sourceAddresses -join ',') → $protos → $fqdns"
                }
            }
        }
    }
} else {
    Write-Host "  (Firewall スキップのため判定不可)" -ForegroundColor DarkGray
}

# ============================================================
# 7. Azure Bastion
# ============================================================
$sectionName = '7. Azure Bastion'
if (-not $SkipBastion) {
    Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

    $basState = az network bastion show -g rg-hub -n bas-hub `
        --query "provisioningState" -o tsv 2>$null
    $basDetail = $null
    if ($Detail -and $basState -eq 'Succeeded') {
        $basJson = az network bastion show -g rg-hub -n bas-hub -o json 2>$null | ConvertFrom-Json
        $basDetail = @{ sku = $basJson.sku.name }
    }
    Test-Val $sectionName 'bas-hub プロビジョニング' $basState 'Succeeded' $basDetail
    if ($basDetail) {
        Write-Detail "SKU: $($basDetail.sku)"
    }
} else {
    Write-Host "`n=== 7. Azure Bastion (スキップ) ===" -ForegroundColor DarkGray
}

# ============================================================
# 8. DNS Private Resolver & Private DNS Zone
# ============================================================
$sectionName = '8. DNS Private Resolver & Private DNS Zone'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

$resolverState = az dns-resolver show -g rg-hub -n dnspr-hub `
    --query "provisioningState" -o tsv 2>$null
Test-Val $sectionName 'dnspr-hub プロビジョニング' $resolverState 'Succeeded'

$inbound = az dns-resolver inbound-endpoint list -g rg-hub --dns-resolver-name dnspr-hub `
    --query "[0].provisioningState" -o tsv 2>$null
$inboundDetail = $null
if ($Detail) {
    $inboundJson = az dns-resolver inbound-endpoint list -g rg-hub --dns-resolver-name dnspr-hub -o json 2>$null | ConvertFrom-Json
    if ($inboundJson -and $inboundJson.Count -gt 0) {
        $ip = $inboundJson[0].ipConfigurations[0].privateIpAddress
        $inboundDetail = @{ privateIp = $ip }
    }
}
Test-Val $sectionName 'Inbound Endpoint' $inbound 'Succeeded' $inboundDetail
if ($inboundDetail) {
    Write-Detail "Inbound IP: $($inboundDetail.privateIp)"
}

$outbound = az dns-resolver outbound-endpoint list -g rg-hub --dns-resolver-name dnspr-hub `
    --query "[0].provisioningState" -o tsv 2>$null
Test-Val $sectionName 'Outbound Endpoint' $outbound 'Succeeded'

# DNS Forwarding Ruleset の詳細
if ($Detail) {
    $rulesetJson = az dns-resolver forwarding-ruleset list -g rg-hub -o json 2>$null | ConvertFrom-Json
    if ($rulesetJson) {
        Write-Detail "Forwarding Ruleset: $($rulesetJson[0].name)"
        $fwdRules = az dns-resolver forwarding-rule list -g rg-hub --dns-forwarding-ruleset-name $rulesetJson[0].name -o json 2>$null | ConvertFrom-Json
        if ($fwdRules) {
            foreach ($fwdRule in $fwdRules) {
                $targets = ($fwdRule.targetDnsServers | ForEach-Object { "$($_.ipAddress):$($_.port)" }) -join ', '
                Write-Detail "  [$($fwdRule.name)] domain=$($fwdRule.domainName) → $targets (state=$($fwdRule.forwardingRuleState))"
            }
        }
    }
}

$pdnsz = az network private-dns zone show -g rg-hub -n privatelink.database.windows.net `
    --query "name" -o tsv 2>$null
Test-Val $sectionName 'Private DNS Zone' $pdnsz 'privatelink.database.windows.net'

$links = az network private-dns link vnet list -g rg-hub -z privatelink.database.windows.net `
    -o json 2>$null | ConvertFrom-Json
$linkCount = if ($links) { $links.Count } else { 0 }
$linkDetail = $null
if ($Detail -and $links) {
    $linkDetail = @{ links = $links | ForEach-Object { @{ name = $_.name; vnetId = $_.virtualNetwork.id.Split('/')[-1]; registrationEnabled = $_.registrationEnabled } } }
}
Test-Bool $sectionName "Private DNS Zone VNet リンク数 >= 4 (実際: $linkCount)" ($linkCount -ge 4) $linkDetail
if ($linkDetail) {
    foreach ($lnk in $links) {
        $vnetShort = $lnk.virtualNetwork.id.Split('/')[-1]
        Write-Detail "VNet Link: $($lnk.name) → $vnetShort (registration=$($lnk.registrationEnabled))"
    }
}

# ============================================================
# 9. Log Analytics Workspace
# ============================================================
$sectionName = '9. Log Analytics Workspace'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

$lawState = az monitor log-analytics workspace show -g rg-hub -n log-hub `
    --query "provisioningState" -o tsv 2>$null
$lawDetail = $null
if ($Detail -and $lawState -eq 'Succeeded') {
    $lawJson = az monitor log-analytics workspace show -g rg-hub -n log-hub -o json 2>$null | ConvertFrom-Json
    $lawDetail = @{
        sku            = $lawJson.sku.name
        retentionDays  = $lawJson.retentionInDays
        dailyCapGb     = $lawJson.workspaceCapping.dailyQuotaGb
    }
}
Test-Val $sectionName 'log-hub プロビジョニング' $lawState 'Succeeded' $lawDetail
if ($lawDetail) {
    Write-Detail "SKU: $($lawDetail.sku), Retention: $($lawDetail.retentionDays) days"
}

# ============================================================
# 10. ポリシー割り当て
# ============================================================
$sectionName = '10. ポリシー割り当て'
Write-Host "`n=== $sectionName ===" -ForegroundColor Cyan

$policyNames = @(
    'policy-allowed-locations'
    'policy-storage-no-public'
    'policy-sql-auditing'
    'policy-sql-no-public'
    'policy-require-env-tag'
    'policy-mgmt-ports-audit'
    'policy-appservice-no-public'
)

$assignmentsJson = az policy assignment list -o json 2>$null | ConvertFrom-Json
$assignments = $assignmentsJson | ForEach-Object { $_.name }

foreach ($pn in $policyNames) {
    $found = $pn -in $assignments
    $policyDetail = $null
    if ($Detail -and $found) {
        $pa = $assignmentsJson | Where-Object { $_.name -eq $pn }
        $policyDetail = @{
            displayName    = $pa.displayName
            enforcementMode = $pa.enforcementMode
            scope          = $pa.scope
            policyDefId    = $pa.policyDefinitionId.Split('/')[-1]
        }
    }
    Test-Bool $sectionName "ポリシー: $pn" $found $policyDetail
    if ($policyDetail) {
        Write-Detail "displayName: $($policyDetail.displayName)"
        Write-Detail "enforcement: $($policyDetail.enforcementMode), scope: $($policyDetail.scope)"
        if ($pa.parameters) {
            $paramStr = ($pa.parameters.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.value)" }) -join ', '
            if ($paramStr) { Write-Detail "params: $paramStr" }
        }
    }
}

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}

# ============================================================
# JSON 出力
# ============================================================
if ($OutputPath) {
    $report = [PSCustomObject]@{
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        summary   = @{ total = $total; passed = $passed; failed = $total - $passed }
        results   = $script:results
    }
    $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding utf8
    Write-Host "`n  JSON レポート保存: $OutputPath" -ForegroundColor Cyan
}
