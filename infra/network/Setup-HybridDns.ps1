# ============================================================
# Setup-HybridDns.ps1
# 双方向 DNS 転送設定 (VPN 接続確立後に実行)
# [1/2] クラウド→オンプレ: DNS Forwarding Ruleset で lab.local を DC01 へ転送
# [2/2] オンプレ→クラウド: DC01 に privatelink.database.windows.net の条件付きフォワーダーを追加
# ============================================================
# 前提条件:
#   - Step 4 (VPN Gateway 配置・接続) 完了済み
#   - az login 済み
# 使い方:
#   .\Setup-HybridDns.ps1
#   .\Setup-HybridDns.ps1 -OnpremResourceGroup rg-onprem -HubResourceGroup rg-hub
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
    [string]$OnpremDomain = 'lab.local'
)

$ErrorActionPreference = 'Stop'

Write-Host '=== Hybrid DNS Setup ===' -ForegroundColor Cyan

# ============================================================
# [1/2] クラウド→オンプレ: DNS Forwarding Ruleset 作成
# ============================================================
Write-Host '[1/2] Setting up Cloud to On-premises DNS forwarding...' -ForegroundColor Yellow

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
az dns-resolver forwarding-ruleset vnet-link create `
    --resource-group $HubResourceGroup `
    --ruleset-name 'dnsrs-hub' `
    --name 'link-vnet-hub' `
    --id $hubVnetId `
    --only-show-errors 2>$null

Write-Host '  Cloud to On-premises DNS forwarding configured.' -ForegroundColor Green

# ============================================================
# [2/2] オンプレ→クラウド: DC01 に条件付きフォワーダーを追加
# ============================================================
Write-Host '[2/2] Setting up On-premises to Cloud DNS forwarding...' -ForegroundColor Yellow

# DNS Private Resolver のインバウンド IP を取得
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

# DC01 に条件付きフォワーダーを追加
Write-Host "  Adding conditional forwarder on $VmName for $ForwardZone..." -ForegroundColor Yellow

$script = @"
`$zone = Get-DnsServerZone -Name '$ForwardZone' -ErrorAction SilentlyContinue
if (`$zone) {
    Write-Host 'Conditional forwarder already exists. Updating MasterServers.'
    Set-DnsServerConditionalForwarderZone -Name '$ForwardZone' -MasterServers '$dnsInboundIp'
} else {
    Add-DnsServerConditionalForwarderZone -Name '$ForwardZone' -MasterServers '$dnsInboundIp' -ReplicationScope Forest
}
"@

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

Write-Host ''
Write-Host '=== Hybrid DNS Setup Complete ===' -ForegroundColor Cyan
