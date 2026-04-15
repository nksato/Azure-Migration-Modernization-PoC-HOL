# ============================================================
# Setup-HybridDns.ps1
# ハイブリッド DNS 転送設定 (VPN 接続確立後に実行)
# [1/4] オンプレ→クラウド: DC01 に Private Link ゾーンの条件付きフォワーダーを追加
# [2/4] クラウド→オンプレ: DNS Forwarding Ruleset で lab.local を DC01 へ転送
# [3/4] オンプレ→クラウド VM: Private DNS Zone (azure.internal) + DC01 条件付きフォワーダー (オプション)
# [4/4] Spoke VNet リンク: Hub ピアリング先を自動検出し Ruleset をリンク (オプション)
# ============================================================
# 前提条件:
#   - Step 4 (VPN Gateway 配置・接続) 完了済み
#   - az login 済み
# 使い方:
#   .\Setup-HybridDns.ps1
#   .\Setup-HybridDns.ps1 -OnpremResourceGroup rg-onprem -HubResourceGroup rg-hub
#   .\Setup-HybridDns.ps1 -EnableCloudVmResolution      # Cloud VM の名前解決を有効化
#   .\Setup-HybridDns.ps1 -LinkSpokeVnets              # Hub ピアリング先 Spoke VNet に Ruleset をリンク
# ============================================================

param(
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$HubVnetName = 'vnet-hub',
    [string]$DnsResolverName = 'dnspr-hub',
    [string]$InboundEndpointName = 'inbound',
    [string]$OutboundEndpointName = 'outbound',
    [string]$RulesetName = 'frs-hub',
    [string]$VmName = 'vm-onprem-ad',
    [string]$DcIp = '10.0.1.4',
    [string]$DomainName = 'lab.local',
    [string]$CloudDnsZone = 'azure.internal',
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

# Azure CLI ログイン確認
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Azure CLI にログインしてください: az login"
}
Write-Host "サブスクリプション: $($account.name) ($($account.id))" -ForegroundColor Green

Write-Host '=== Hybrid DNS Setup ===' -ForegroundColor Cyan
Write-Host '  [1/4] オンプレ → クラウド: DC01 の条件付きフォワーダーで Private DNS Zone を Resolver へ転送' -ForegroundColor Cyan
Write-Host '  [2/4] クラウド → オンプレ: DNS Forwarding Ruleset で AD ドメインを DC01 へ転送' -ForegroundColor Cyan
if ($EnableCloudVmResolution) {
    Write-Host '  [3/4] オンプレ → クラウド VM: Private DNS Zone + DC01 条件付きフォワーダー' -ForegroundColor Cyan
} else {
    Write-Host '  [3/4] スキップ (use -EnableCloudVmResolution to enable)' -ForegroundColor DarkGray
}
if ($LinkSpokeVnets) {
    Write-Host '  [4/4] Spoke VNet リンク: Forwarding Ruleset を Spoke VNet にリンク (ピアリング自動検出)' -ForegroundColor Cyan
} else {
    Write-Host '  [4/4] スキップ (use -LinkSpokeVnets to enable)' -ForegroundColor DarkGray
}

# ============================================================
# DNS Private Resolver インバウンド IP 取得 ([1/4] と [3/4] で共用)
# ============================================================
Write-Host '  Getting DNS Resolver inbound IP...' -ForegroundColor Yellow
$dnsInboundIp = az dns-resolver inbound-endpoint show `
    --resource-group $HubResourceGroup `
    --dns-resolver-name $DnsResolverName `
    --name $InboundEndpointName `
    --query "ipConfigurations[0].privateIpAddress" -o tsv

if (-not $dnsInboundIp) {
    Write-Error "DNS Resolver inbound IP not found: $HubResourceGroup/$DnsResolverName/$InboundEndpointName"
    exit 1
}
Write-Host "  DNS Resolver inbound IP: $dnsInboundIp" -ForegroundColor Green

# ============================================================
# Hub VNet 情報取得 + Spoke VNet 自動検出
# ============================================================
$hubVnetId = az network vnet show `
    --resource-group $HubResourceGroup `
    --name $HubVnetName `
    --query "id" -o tsv

if (-not $hubVnetId) {
    throw "Hub VNet not found: $HubResourceGroup/$HubVnetName"
}
Write-Host "  Hub VNet: $HubVnetName" -ForegroundColor Green

# Hub にピアリングされた Spoke VNet を自動検出
$spokeVnets = az network vnet peering list `
    -g $HubResourceGroup --vnet-name $HubVnetName `
    --query '[].{name: name, vnetId: remoteVirtualNetwork.id}' -o json | ConvertFrom-Json

if (-not $spokeVnets) { $spokeVnets = @() }

if ($spokeVnets.Count -gt 0) {
    Write-Host "  Spoke VNets (ピアリング検出): $($spokeVnets.Count) 件" -ForegroundColor Green
    foreach ($s in $spokeVnets) {
        Write-Host "    - $(($s.vnetId -split '/')[-1])"
    }
} else {
    Write-Host '  Spoke VNets: ピアリングなし' -ForegroundColor DarkGray
}

# ============================================================
# [1/4] オンプレ→クラウド: DC01 に条件付きフォワーダーを追加
# ============================================================
Write-Host '[1/4] オンプレ → クラウド: DC01 に条件付きフォワーダーを追加中...' -ForegroundColor Yellow
Write-Host "  Private Link ゾーンのクエリを DNS Resolver ($dnsInboundIp) へ転送します" -ForegroundColor Yellow

# DC01 に条件付きフォワーダーを追加
$zonesArray = ($privateLinkZones | ForEach-Object { "'$_'" }) -join ','

$script = @"
`$zones = @($zonesArray)
foreach (`$z in `$zones) {
    `$existing = Get-DnsServerZone -Name `$z -ErrorAction SilentlyContinue
    if (`$existing) {
        Set-DnsServerConditionalForwarderZone -Name `$z -MasterServers '$dnsInboundIp'
        Write-Output "  `$z - updated."
    } else {
        Add-DnsServerConditionalForwarderZone -Name `$z -MasterServers '$dnsInboundIp' -ReplicationScope Forest
        Write-Output "  `$z - created."
    }
}
"@

az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts $script `
    --query "value[].message" -o tsv

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to add conditional forwarders on $VmName."
    exit 1
}

Write-Host '  Conditional forwarders configured.' -ForegroundColor Green

# ============================================================
# [2/4] クラウド→オンプレ: DNS Forwarding Ruleset 作成
# ============================================================
Write-Host '[2/4] クラウド → オンプレ: DNS Forwarding Ruleset を作成中...' -ForegroundColor Yellow
Write-Host "  $DomainName のクエリを DC01 ($DcIp) へ転送します" -ForegroundColor Yellow

# DNS Resolver の Outbound Endpoint ID を取得
Write-Host '  Getting DNS Resolver outbound endpoint...' -ForegroundColor Yellow
$outboundEpId = az dns-resolver outbound-endpoint show `
    --resource-group $HubResourceGroup `
    --dns-resolver-name $DnsResolverName `
    --name $OutboundEndpointName `
    --query "id" -o tsv

if (-not $outboundEpId) {
    Write-Error "DNS Resolver outbound endpoint not found: $HubResourceGroup/$DnsResolverName/$OutboundEndpointName"
    exit 1
}
Write-Host "  Outbound endpoint: $outboundEpId" -ForegroundColor Green

# DNS Forwarding Ruleset を作成 (既存ならスキップ)
$existingRuleset = az dns-resolver forwarding-ruleset show `
    -g $HubResourceGroup -n $RulesetName --query 'id' -o tsv 2>$null
if ($existingRuleset) {
    Write-Host "  Ruleset '$RulesetName' already exists. Skipping."
} else {
    Write-Host '  Creating DNS Forwarding Ruleset...' -ForegroundColor Yellow
    $location = az group show --name $HubResourceGroup --query "location" -o tsv
    az dns-resolver forwarding-ruleset create `
        --resource-group $HubResourceGroup `
        --name $RulesetName `
        --location $location `
        --outbound-endpoints "[{id:$outboundEpId}]" `
        -o none
    Write-Host "  Ruleset '$RulesetName' created."
}

# 転送ルール名をドメイン名から動的生成 (lab.local -> lab-local)
$ruleName = ($DomainName -replace '\.', '-')

# 転送ルール: DomainName → DC (既存なら更新)
$existingRule = az dns-resolver forwarding-rule show `
    -g $HubResourceGroup --ruleset-name $RulesetName `
    -n $ruleName --query 'domainName' -o tsv 2>$null
if ($existingRule) {
    Write-Host "  Rule '$ruleName' already exists. Updating target..." -ForegroundColor Yellow
    az dns-resolver forwarding-rule update `
        -g $HubResourceGroup --ruleset-name $RulesetName `
        -n $ruleName `
        --target-dns-servers "[{ip-address:$DcIp,port:53}]" `
        -o none
    Write-Host "  Rule '$ruleName' updated."
} else {
    Write-Host "  Creating forwarding rule: $DomainName -> $DcIp..." -ForegroundColor Yellow
    az dns-resolver forwarding-rule create `
        --resource-group $HubResourceGroup `
        --ruleset-name $RulesetName `
        --name $ruleName `
        --domain-name "${DomainName}." `
        --forwarding-rule-state 'Enabled' `
        --target-dns-servers "[{ip-address:$DcIp,port:53}]" `
        -o none
    Write-Host "  Rule '$ruleName' created."
}

# ルールセットを Hub VNet にリンク (既存ならスキップ)
$existingHubLink = az dns-resolver forwarding-ruleset list-by-virtual-network `
    --resource-group $HubResourceGroup --virtual-network-name $HubVnetName `
    --query "[?name=='$RulesetName'].id" -o tsv 2>$null
if ($existingHubLink) {
    Write-Host "  Hub VNet link already exists. Skipping."
} else {
    Write-Host "  Linking ruleset to $HubVnetName..." -ForegroundColor Yellow
    az dns-resolver vnet-link create `
        --resource-group $HubResourceGroup `
        --ruleset-name $RulesetName `
        --name "link-$HubVnetName" `
        --id $hubVnetId `
        -o none
    Write-Host "  Hub VNet linked."
}

Write-Host '  Cloud to On-premises DNS forwarding configured.' -ForegroundColor Green

# ============================================================
# [3/4] オンプレ→クラウド VM 名前解決: Private DNS Zone + DC01 条件付きフォワーダー (オプション)
# ============================================================
if ($EnableCloudVmResolution) {
    Write-Host "[3/4] オンプレ → クラウド VM: Private DNS Zone ($CloudDnsZone) を構成中..." -ForegroundColor Yellow

    # Private DNS Zone を作成
    Write-Host "  Creating Private DNS Zone: $CloudDnsZone..." -ForegroundColor Yellow
    az network private-dns zone create `
        --resource-group $HubResourceGroup `
        --name $CloudDnsZone `
        --only-show-errors 2>$null

    # Hub VNet にリンク (自動登録なし — Hub に VM は配置しない想定)
    Write-Host "  Linking Private DNS Zone to $HubVnetName..." -ForegroundColor Yellow
    az network private-dns link vnet create `
        --resource-group $HubResourceGroup `
        --zone-name $CloudDnsZone `
        --name "link-$HubVnetName" `
        --virtual-network $hubVnetId `
        --registration-enabled false `
        --only-show-errors 2>$null

    # Spoke VNet にリンク (自動登録有効 — VM の A レコードを自動作成、ピアリング自動検出)
    if ($spokeVnets.Count -gt 0) {
        foreach ($spoke in $spokeVnets) {
            $spokeName = ($spoke.vnetId -split '/')[-1]
            Write-Host "  Linking $CloudDnsZone to $spokeName (registration enabled)..." -ForegroundColor Yellow
            az network private-dns link vnet create `
                --resource-group $HubResourceGroup `
                --zone-name $CloudDnsZone `
                --name "link-$spokeName" `
                --virtual-network $spoke.vnetId `
                --registration-enabled true `
                --only-show-errors 2>$null
        }
    } else {
        Write-Host '  ピアリングされた Spoke VNet なし。スキップ。' -ForegroundColor DarkGray
    }

    # DC01 に azure.internal の条件付きフォワーダーを追加
    Write-Host "  Adding conditional forwarder on $VmName for $CloudDnsZone..." -ForegroundColor Yellow

    $cloudScript = "`$zone = Get-DnsServerZone -Name '$CloudDnsZone' -ErrorAction SilentlyContinue; if (`$zone) { Set-DnsServerConditionalForwarderZone -Name '$CloudDnsZone' -MasterServers '$dnsInboundIp' } else { Add-DnsServerConditionalForwarderZone -Name '$CloudDnsZone' -MasterServers '$dnsInboundIp' -ReplicationScope Forest }"

    az vm run-command invoke `
        --resource-group $OnpremResourceGroup `
        --name $VmName `
        --command-id RunPowerShellScript `
        --scripts $cloudScript `
        --query "value[].message" -o tsv

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to add conditional forwarder for $CloudDnsZone on $VmName."
        exit 1
    }

    Write-Host '  Cloud VM name resolution configured.' -ForegroundColor Green
} else {
    Write-Host '[3/4] Cloud VM 名前解決スキップ (use -EnableCloudVmResolution to enable).' -ForegroundColor DarkGray
}

# ============================================================
# [4/4] Spoke VNet リンク: Forwarding Ruleset を Spoke VNet にリンク (オプション、ピアリング自動検出)
# ============================================================
if ($LinkSpokeVnets) {
    Write-Host '[4/4] Spoke VNet リンク: Forwarding Ruleset を Spoke VNet にリンク中...' -ForegroundColor Yellow
    if ($spokeVnets.Count -eq 0) {
        Write-Host '  ピアリングされた Spoke VNet なし。スキップ。' -ForegroundColor DarkGray
    } else {
        foreach ($spoke in $spokeVnets) {
            $spokeName = ($spoke.vnetId -split '/')[-1]
            $linkName = "link-$spokeName"
            Write-Host "  Linking ruleset to $spokeName..." -ForegroundColor Yellow
            az dns-resolver vnet-link create `
                --resource-group $HubResourceGroup `
                --ruleset-name $RulesetName `
                --name $linkName `
                --id $spoke.vnetId `
                --only-show-errors 2>$null
        }
        Write-Host '  Spoke VNet linking configured.' -ForegroundColor Green
    }
} else {
    Write-Host '[4/4] Spoke VNet リンクスキップ (use -LinkSpokeVnets to enable).' -ForegroundColor DarkGray
}

# ============================================================
# 検証
# ============================================================
Write-Host '' -ForegroundColor White
Write-Host '=== Verification ===' -ForegroundColor Cyan

Write-Host 'DC01 Conditional Forwarders:' -ForegroundColor White
az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts "Get-DnsServerZone | Where-Object { `$_.ZoneType -eq 'Forwarder' } | Format-List ZoneName,ZoneType,MasterServers" `
    --query "value[].message" -o tsv

Write-Host '' -ForegroundColor White
Write-Host 'DNS Forwarding Ruleset:' -ForegroundColor White
az dns-resolver forwarding-rule list `
    --resource-group $HubResourceGroup `
    --ruleset-name $RulesetName `
    --query "[].{Name:name, Domain:domainName, State:forwardingRuleState, Target:targetDnsServers[0].ipAddress}" `
    -o table

if ($EnableCloudVmResolution) {
    Write-Host '' -ForegroundColor White
    Write-Host 'Private DNS Zone (Cloud VM):' -ForegroundColor White
    az network private-dns zone show `
        --resource-group $HubResourceGroup `
        --name $CloudDnsZone `
        --query "{Name:name, RecordSets:numberOfRecordSets, VNetLinks:numberOfVirtualNetworkLinks}" `
        -o table

    Write-Host '' -ForegroundColor White
    Write-Host "DC01 Conditional Forwarder ($CloudDnsZone):" -ForegroundColor White
    az vm run-command invoke `
        --resource-group $OnpremResourceGroup `
        --name $VmName `
        --command-id RunPowerShellScript `
        --scripts "Get-DnsServerZone -Name '$CloudDnsZone' | Format-List ZoneName,ZoneType,MasterServers" `
        --query "value[].message" -o tsv
}

if ($LinkSpokeVnets) {
    Write-Host '' -ForegroundColor White
    Write-Host 'Spoke VNet Links (Forwarding Ruleset):' -ForegroundColor White
    az dns-resolver vnet-link list `
        --resource-group $HubResourceGroup `
        --ruleset-name $RulesetName `
        --query "[].{Name:name, VNet:virtualNetwork.id}" `
        -o table
}

Write-Host ''
Write-Host '=== Hybrid DNS Setup Complete ===' -ForegroundColor Cyan
