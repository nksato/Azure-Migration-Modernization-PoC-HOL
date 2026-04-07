# ============================================================
# Setup-HybridDns.ps1
# ハイブリッド DNS 転送設定 (VPN 接続確立後に実行)
# [1/3] クラウド→オンプレ: DNS Forwarding Ruleset で lab.local を DC01 へ転送
# [2/3] オンプレ→クラウド: DC01 に privatelink.database.windows.net の条件付きフォワーダーを追加
# [3/3] オンプレ→クラウド VM: Private DNS Zone (azure.internal) + DC01 条件付きフォワーダー (オプション)
# ============================================================
# 前提条件:
#   - Step 4 (VPN Gateway 配置・接続) 完了済み
#   - az login 済み
# 使い方:
#   .\Setup-HybridDns.ps1
#   .\Setup-HybridDns.ps1 -OnpremResourceGroup rg-onprem -HubResourceGroup rg-hub
#   .\Setup-HybridDns.ps1 -LinkSpokeVnets              # Spoke VNet にも Ruleset をリンク
#   .\Setup-HybridDns.ps1 -EnableCloudVmResolution      # Cloud VM の名前解決を有効化
# ============================================================

param(
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$DnsResolverName = 'dnspr-hub',
    [string]$InboundEndpointName = 'inbound',
    [string]$OutboundEndpointName = 'outbound',
    [string]$VmName = 'vm-onprem-ad',
    [string]$ForwardZone = 'privatelink.database.windows.net',
    [string]$OnpremDnsTarget = '10.0.1.4',
    [string]$OnpremDomain = 'lab.local',
    [string]$CloudDnsZone = 'azure.internal',
    [switch]$LinkSpokeVnets,
    [switch]$EnableCloudVmResolution
)

$ErrorActionPreference = 'Stop'

# Azure CLI ログイン確認
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Azure CLI にログインしてください: az login"
}
Write-Host "サブスクリプション: $($account.name) ($($account.id))" -ForegroundColor Green

Write-Host '=== Hybrid DNS Setup ===' -ForegroundColor Cyan
Write-Host '  [1/3] クラウド → オンプレ: DNS Forwarding Ruleset で AD ドメインを DC01 へ転送' -ForegroundColor Cyan
Write-Host '  [2/3] オンプレ → クラウド: DC01 の条件付きフォワーダーで Private DNS Zone を Resolver へ転送' -ForegroundColor Cyan
if ($EnableCloudVmResolution) {
    Write-Host '  [3/3] オンプレ → クラウド VM: Private DNS Zone + DC01 条件付きフォワーダー' -ForegroundColor Cyan
} else {
    Write-Host '  [3/3] スキップ (use -EnableCloudVmResolution to enable)' -ForegroundColor DarkGray
}

# ============================================================
# [1/3] クラウド→オンプレ: DNS Forwarding Ruleset 作成
# ============================================================
Write-Host '[1/3] クラウド → オンプレ: DNS Forwarding Ruleset を作成中...' -ForegroundColor Yellow
Write-Host "  $OnpremDomain のクエリを DC01 ($OnpremDnsTarget) へ転送します" -ForegroundColor Yellow

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

# Hub VNet ID を取得
$hubVnetId = az network vnet show `
    --resource-group $HubResourceGroup `
    --name 'vnet-hub' `
    --query "id" -o tsv

# DNS Forwarding Ruleset を作成
Write-Host '  Creating DNS Forwarding Ruleset...' -ForegroundColor Yellow
az dns-resolver forwarding-ruleset create `
    --resource-group $HubResourceGroup `
    --name 'dnsrs-hub' `
    --location (az group show --name $HubResourceGroup --query "location" -o tsv) `
    --outbound-endpoints "[{id:$outboundEpId}]" `
    --only-show-errors 2>$null

# 転送ルール: lab.local → DC01
Write-Host "  Creating forwarding rule: $OnpremDomain -> $OnpremDnsTarget..." -ForegroundColor Yellow
az dns-resolver forwarding-rule create `
    --resource-group $HubResourceGroup `
    --ruleset-name 'dnsrs-hub' `
    --name 'rule-lab-local' `
    --domain-name "${OnpremDomain}." `
    --forwarding-rule-state 'Enabled' `
    --target-dns-servers "[{ip-address:$OnpremDnsTarget,port:53}]" `
    --only-show-errors 2>$null

# ルールセットを Hub VNet にリンク
Write-Host '  Linking ruleset to Hub VNet...' -ForegroundColor Yellow
az dns-resolver vnet-link create `
    --resource-group $HubResourceGroup `
    --ruleset-name 'dnsrs-hub' `
    --name 'link-vnet-hub' `
    --id $hubVnetId `
    --only-show-errors 2>$null

# ルールセットを Spoke VNet にもリンク (Spoke VM からオンプレ名前解決に必要)
if ($LinkSpokeVnets) {
$spokeVnets = @(
    @{ rg = 'rg-spoke1'; vnet = 'vnet-spoke1'; link = 'link-vnet-spoke1' }
    @{ rg = 'rg-spoke2'; vnet = 'vnet-spoke2'; link = 'link-vnet-spoke2' }
    @{ rg = 'rg-spoke3'; vnet = 'vnet-spoke3'; link = 'link-vnet-spoke3' }
    @{ rg = 'rg-spoke4'; vnet = 'vnet-spoke4'; link = 'link-vnet-spoke4' }
)
foreach ($spoke in $spokeVnets) {
    $spokeVnetId = az network vnet show -g $spoke.rg -n $spoke.vnet --query "id" -o tsv 2>$null
    if ($spokeVnetId) {
        Write-Host "  Linking ruleset to $($spoke.vnet)..." -ForegroundColor Yellow
        az dns-resolver vnet-link create `
            --resource-group $HubResourceGroup `
            --ruleset-name 'dnsrs-hub' `
            --name $spoke.link `
            --id $spokeVnetId `
            --only-show-errors 2>$null
    } else {
        Write-Host "  $($spoke.vnet) not found, skipping link." -ForegroundColor DarkGray
    }
}
} else {
    Write-Host '  Spoke VNet linking skipped (use -LinkSpokeVnets to enable).' -ForegroundColor DarkGray
}

Write-Host '  Cloud to On-premises DNS forwarding configured.' -ForegroundColor Green

# ============================================================
# DNS Private Resolver インバウンド IP 取得 ([2/3] と [3/3] で共用)
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
# [2/3] オンプレ→クラウド: DC01 に条件付きフォワーダーを追加
# ============================================================
Write-Host '[2/3] オンプレ → クラウド: DC01 に条件付きフォワーダーを追加中...' -ForegroundColor Yellow
Write-Host "  $ForwardZone のクエリを DNS Resolver ($dnsInboundIp) へ転送します" -ForegroundColor Yellow

# DC01 に条件付きフォワーダーを追加
Write-Host "  Adding conditional forwarder on $VmName for $ForwardZone..." -ForegroundColor Yellow

$script = "`$zone = Get-DnsServerZone -Name '$ForwardZone' -ErrorAction SilentlyContinue; if (`$zone) { Set-DnsServerConditionalForwarderZone -Name '$ForwardZone' -MasterServers '$dnsInboundIp' } else { Add-DnsServerConditionalForwarderZone -Name '$ForwardZone' -MasterServers '$dnsInboundIp' -ReplicationScope Forest }"

az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts $script `
    --query "value[].message" -o tsv

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to add conditional forwarder on $VmName."
    exit 1
}

Write-Host '  Conditional forwarder configured.' -ForegroundColor Green

# ============================================================
# [3/3] オンプレ→クラウド VM 名前解決: Private DNS Zone + DC01 条件付きフォワーダー (オプション)
# ============================================================
if ($EnableCloudVmResolution) {
    Write-Host "[3/3] オンプレ → クラウド VM: Private DNS Zone ($CloudDnsZone) を構成中..." -ForegroundColor Yellow

    # Private DNS Zone を作成
    Write-Host "  Creating Private DNS Zone: $CloudDnsZone..." -ForegroundColor Yellow
    az network private-dns zone create `
        --resource-group $HubResourceGroup `
        --name $CloudDnsZone `
        --only-show-errors 2>$null

    # Hub VNet にリンク (自動登録なし — Hub に VM は配置しない想定)
    Write-Host '  Linking Private DNS Zone to vnet-hub...' -ForegroundColor Yellow
    az network private-dns link vnet create `
        --resource-group $HubResourceGroup `
        --zone-name $CloudDnsZone `
        --name 'link-vnet-hub' `
        --virtual-network $hubVnetId `
        --registration-enabled false `
        --only-show-errors 2>$null

    # Spoke VNet にリンク (自動登録有効 — VM の A レコードを自動作成)
    $spokeVnetsForDns = @(
        @{ rg = 'rg-spoke1'; vnet = 'vnet-spoke1'; link = 'link-vnet-spoke1' }
        @{ rg = 'rg-spoke2'; vnet = 'vnet-spoke2'; link = 'link-vnet-spoke2' }
        @{ rg = 'rg-spoke3'; vnet = 'vnet-spoke3'; link = 'link-vnet-spoke3' }
        @{ rg = 'rg-spoke4'; vnet = 'vnet-spoke4'; link = 'link-vnet-spoke4' }
    )
    foreach ($spoke in $spokeVnetsForDns) {
        $spokeVnetId = az network vnet show -g $spoke.rg -n $spoke.vnet --query "id" -o tsv 2>$null
        if ($spokeVnetId) {
            Write-Host "  Linking $CloudDnsZone to $($spoke.vnet) (registration enabled)..." -ForegroundColor Yellow
            az network private-dns link vnet create `
                --resource-group $HubResourceGroup `
                --zone-name $CloudDnsZone `
                --name $spoke.link `
                --virtual-network $spokeVnetId `
                --registration-enabled true `
                --only-show-errors 2>$null
        } else {
            Write-Host "  $($spoke.vnet) not found, skipping link." -ForegroundColor DarkGray
        }
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
    Write-Host '[3/3] Cloud VM 名前解決スキップ (use -EnableCloudVmResolution to enable).' -ForegroundColor DarkGray
}

# ============================================================
# 検証
# ============================================================
Write-Host '' -ForegroundColor White
Write-Host '=== Verification ===' -ForegroundColor Cyan

Write-Host 'DNS Forwarding Ruleset:' -ForegroundColor White
az dns-resolver forwarding-rule list `
    --resource-group $HubResourceGroup `
    --ruleset-name 'dnsrs-hub' `
    --query "[].{Name:name, Domain:domainName, State:forwardingRuleState, Target:targetDnsServers[0].ipAddress}" `
    -o table

Write-Host '' -ForegroundColor White
Write-Host 'DC01 Conditional Forwarder:' -ForegroundColor White
az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts "Get-DnsServerZone -Name '$ForwardZone' | Format-List ZoneName,ZoneType,MasterServers" `
    --query "value[].message" -o tsv

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

Write-Host ''
Write-Host '=== Hybrid DNS Setup Complete ===' -ForegroundColor Cyan
