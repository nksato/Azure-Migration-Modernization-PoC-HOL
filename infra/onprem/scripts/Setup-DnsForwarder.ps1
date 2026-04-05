# ============================================================
# Setup-DnsForwarder.ps1
# DC01 に DNS 条件付きフォワーダーを設定する
# - DNS Private Resolver のインバウンド IP を取得
# - DC01 に privatelink.database.windows.net の条件付きフォワーダーを追加
# - 設定結果を確認
# ============================================================
# 使い方:
#   .\Setup-DnsForwarder.ps1
#   .\Setup-DnsForwarder.ps1 -OnpremResourceGroup rg-onprem -HubResourceGroup rg-hub
# ============================================================

param(
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$DnsResolverName = 'dnspr-hub',
    [string]$InboundEndpointName = 'inbound',
    [string]$VmName = 'vm-onprem-ad',
    [string]$ForwardZone = 'privatelink.database.windows.net'
)

$ErrorActionPreference = 'Stop'

Write-Host '=== DNS 条件付きフォワーダー セットアップ開始 ===' -ForegroundColor Cyan

# ----------------------------------------------------------
# 1. DNS Private Resolver のインバウンド IP を取得
# ----------------------------------------------------------
Write-Host '[1/3] DNS Private Resolver のインバウンド IP を取得...' -ForegroundColor Yellow

$dnsInboundIp = az dns-resolver inbound-endpoint show `
    --resource-group $HubResourceGroup `
    --dns-resolver-name $DnsResolverName `
    --name $InboundEndpointName `
    --query "ipConfigurations[0].privateIpAddress" -o tsv

if (-not $dnsInboundIp) {
    Write-Error "DNS Private Resolver のインバウンド IP を取得できませんでした。$HubResourceGroup/$DnsResolverName/$InboundEndpointName を確認してください。"
    exit 1
}

Write-Host "  インバウンド IP: $dnsInboundIp" -ForegroundColor Green

# ----------------------------------------------------------
# 2. DC01 に条件付きフォワーダーを追加
# ----------------------------------------------------------
Write-Host "[2/3] $VmName に $ForwardZone の条件付きフォワーダーを追加..." -ForegroundColor Yellow

$script = "`$zone = Get-DnsServerZone -Name '$ForwardZone' -ErrorAction SilentlyContinue; if (`$zone) { Set-DnsServerConditionalForwarderZone -Name '$ForwardZone' -MasterServers '$dnsInboundIp' } else { Add-DnsServerConditionalForwarderZone -Name '$ForwardZone' -MasterServers '$dnsInboundIp' -ReplicationScope Forest }"

az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts $script

if ($LASTEXITCODE -ne 0) {
    Write-Error "条件付きフォワーダーの追加に失敗しました。"
    exit 1
}

Write-Host '  条件付きフォワーダーを設定しました。' -ForegroundColor Green

# ----------------------------------------------------------
# 3. 設定結果を確認
# ----------------------------------------------------------
Write-Host '[3/3] 設定結果を確認...' -ForegroundColor Yellow

az vm run-command invoke `
    --resource-group $OnpremResourceGroup `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts "Get-DnsServerZone -Name '$ForwardZone' | Format-List ZoneName,ZoneType,MasterServers"

Write-Host '=== DNS 条件付きフォワーダー セットアップ完了 ===' -ForegroundColor Cyan
