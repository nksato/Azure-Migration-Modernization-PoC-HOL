<#
.SYNOPSIS
    ハイブリッド DNS 構成の状態と双方向疎通を検証する
.DESCRIPTION
    Azure CLI と az vm run-command で DNS 設定状態・名前解決を確認する。
    Azure API + VM 内の DNS 解決結果で判定する簡易チェック。
    ブラウザやポータル画面での目視確認は含まない。
.EXAMPLE
    .\Verify-HybridDns.ps1
#>

[CmdletBinding()]
param(
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$HubResourceGroup = 'rg-hub'
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# --- ヘルパー ---

function Invoke-VmCommand ([string]$ResourceGroup, [string]$VmName, [string]$Script) {
    $oneLiner = ($Script -split "`r?`n" | Where-Object { $_.Trim() }) -join '; '
    $json = az vm run-command invoke `
        --resource-group $ResourceGroup --name $VmName `
        --command-id RunPowerShellScript --scripts $oneLiner -o json 2>&1
    $r = ($json | Where-Object { $_ -is [string] }) -join '' | ConvertFrom-Json
    $stderr = ($r.value | Where-Object { $_.code -like '*stderr*' }).message
    if ($stderr) { Write-Host "         stderr: $stderr" -ForegroundColor DarkYellow }
    ($r.value | Where-Object { $_.code -like '*stdout*' }).message
}

function Get-Val ([string]$Output, [string]$Key) {
    $line = ($Output -split "`n") | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($line) { ($line -replace "^${Key}=", '').Trim() } else { '' }
}

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
# 1. DNS Private Resolver 状態
# ============================================================
Write-Host "`n=== 1. DNS Private Resolver ===" -ForegroundColor Cyan

$resolverState = az dns-resolver show -g $HubResourceGroup -n dnspr-hub `
    --query "provisioningState" -o tsv 2>$null
Test-Val 'dnspr-hub プロビジョニング' $resolverState 'Succeeded'

$inboundIp = az dns-resolver inbound-endpoint show -g $HubResourceGroup `
    --dns-resolver-name dnspr-hub --name inbound `
    --query "ipConfigurations[0].privateIpAddress" -o tsv 2>$null
Test-NotEmpty 'Inbound Endpoint IP' $inboundIp

$outboundState = az dns-resolver outbound-endpoint show -g $HubResourceGroup `
    --dns-resolver-name dnspr-hub --name outbound `
    --query "provisioningState" -o tsv 2>$null
Test-Val 'Outbound Endpoint' $outboundState 'Succeeded'

# ============================================================
# 2. DNS Forwarding Ruleset (クラウド → オンプレ)
# ============================================================
Write-Host "`n=== 2. DNS Forwarding Ruleset (クラウド → オンプレ) ===" -ForegroundColor Cyan

$rulesetState = az dns-resolver forwarding-ruleset show -g $HubResourceGroup -n dnsrs-hub `
    --query "provisioningState" -o tsv 2>$null
Test-Val 'dnsrs-hub プロビジョニング' $rulesetState 'Succeeded'

# 転送ルール一覧を取得
$rulesJson = az dns-resolver forwarding-rule list -g $HubResourceGroup --ruleset-name dnsrs-hub `
    --query "[].{name:name, domain:domainName, state:forwardingRuleState, target:targetDnsServers[0].ipAddress}" `
    -o json 2>$null
if ($rulesJson) {
    $rules = $rulesJson | ConvertFrom-Json
    $labRule = $rules | Where-Object { $_.domain -match 'lab\.local' }
    if ($labRule) {
        Test-Val  '転送ルール状態'         $labRule.state  'Enabled'
        Test-Val  '転送先 (DC01)'          $labRule.target '10.0.1.4'
        Write-Host "         ドメイン: $($labRule.domain)" -ForegroundColor Gray
    } else {
        Test-Val 'lab.local 転送ルール' '(未検出)' 'Enabled'
    }
} else {
    Test-Val 'dnsrs-hub 転送ルール' '(未検出)' 'Enabled'
}

# VNet リンク
$vnetLinks = az dns-resolver forwarding-ruleset vnet-link list -g $HubResourceGroup `
    --ruleset-name dnsrs-hub -o json 2>$null | ConvertFrom-Json
$vnetLinkCount = if ($vnetLinks) { $vnetLinks.Count } else { 0 }
Test-Bool "Ruleset VNet リンク数 >= 1 (実際: $vnetLinkCount)" ($vnetLinkCount -ge 1)

# ============================================================
# 3. DC01 条件付きフォワーダー (オンプレ → クラウド)
# ============================================================
Write-Host "`n=== 3. DC01 条件付きフォワーダー (オンプレ → クラウド) ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

$fwdOut = Invoke-VmCommand $OnpremResourceGroup 'vm-onprem-ad' @'
$zn = 'privatelink.database.windows.net'
$z = Get-DnsServerZone -Name $zn -ErrorAction SilentlyContinue
if ($z) { Write-Output ('ZONE_TYPE=' + $z.ZoneType); Write-Output ('MASTER_SERVERS=' + ($z.MasterServers -join ',')) } else { Write-Output 'ZONE_TYPE='; Write-Output 'MASTER_SERVERS=' }
'@

$zoneType = Get-Val $fwdOut 'ZONE_TYPE'
$masterServers = Get-Val $fwdOut 'MASTER_SERVERS'
Test-Val      '条件付きフォワーダー種別' $zoneType      'Forwarder'
Test-NotEmpty '転送先 IP'                $masterServers

if ($inboundIp -and $masterServers) {
    $match = $masterServers -match [regex]::Escape($inboundIp)
    Test-Bool "転送先が Inbound IP ($inboundIp) と一致" $match
} else {
    Test-Bool '転送先が Inbound IP と一致' $false
}

# ============================================================
# 4. 設定情報サマリ
# ============================================================
Write-Host "`n=== 4. 設定情報サマリ ===" -ForegroundColor Cyan
Write-Host "  DNS Resolver Inbound IP  : $inboundIp" -ForegroundColor Gray
Write-Host "  Forwarding Ruleset       : dnsrs-hub" -ForegroundColor Gray
Write-Host "  転送ルール (→ オンプレ)  : lab.local → 10.0.1.4" -ForegroundColor Gray
Write-Host "  条件付きフォワーダー     : privatelink.database.windows.net → $masterServers" -ForegroundColor Gray

# ============================================================
# 5. 疎通テスト: オンプレ → クラウド (名前解決)
# ============================================================
Write-Host "`n=== 5. 疎通テスト: オンプレ → クラウド ===" -ForegroundColor Cyan
Write-Host "  DC01 から名前解決テスト実行中..." -ForegroundColor Gray

$resolveOut = Invoke-VmCommand $OnpremResourceGroup 'vm-onprem-ad' @'
$r1 = Resolve-DnsName 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('PLINK_RESOLVE=' + $(if ($r1) {'OK'} else {'NG'}))
$r2 = Resolve-DnsName 'dnspr-hub.lab.local' -Server 10.10.5.4 -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('DNS_QUERY=' + $(if ($r2 -or $LASTEXITCODE -eq 0) {'OK'} else {'NG'}))
$t = Test-NetConnection -ComputerName 10.10.5.4 -Port 53 -WarningAction SilentlyContinue
Write-Output ('DNS_TCP=' + $t.TcpTestSucceeded)
'@

Test-Val 'DC01 → privatelink.database.windows.net 解決'  (Get-Val $resolveOut 'PLINK_RESOLVE') 'OK'
# DNS は通常 UDP:53。TCP:53 は閉じている場合があるため参考値
$dnsTcp = Get-Val $resolveOut 'DNS_TCP'
Write-Host "         DC01 → DNS Resolver (10.10.5.4) TCP:53: $dnsTcp (DNS は主に UDP のため参考値)" -ForegroundColor Gray

# ============================================================
# 6. 疎通テスト: クラウド → オンプレ (名前解決)
# ============================================================
Write-Host "`n=== 6. 疎通テスト: クラウド → オンプレ ===" -ForegroundColor Cyan

# Spoke 側の VM が存在するか確認 (spoke1 の Web VM をテストに使う)
# 存在しない場合は Hub 側の Bastion 等から確認するしかないが、
# ここでは Azure CLI の az network dns-resolver で間接確認する

# 方法: DC01 自身で自分のドメインが引けるか (基本確認)
Write-Host "  DC01 から AD ドメインの名前解決を確認..." -ForegroundColor Gray

$adResolveOut = Invoke-VmCommand $OnpremResourceGroup 'vm-onprem-ad' @'
$d = Get-ADDomain
$r = Resolve-DnsName $d.DNSRoot -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('AD_DOMAIN=' + $d.DNSRoot)
Write-Output ('AD_RESOLVE=' + $(if ($r) {'OK'} else {'NG'}))
$dc = Resolve-DnsName ('DC01.' + $d.DNSRoot) -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('DC_RESOLVE=' + $(if ($dc) { $dc[0].IPAddress } else {'NG'}))
'@

$adDomain = Get-Val $adResolveOut 'AD_DOMAIN'
Test-Val      "DC01 → $adDomain 解決"       (Get-Val $adResolveOut 'AD_RESOLVE') 'OK'
Test-NotEmpty "DC01 → DC01.$adDomain 解決"   (Get-Val $adResolveOut 'DC_RESOLVE')

# Spoke VM が存在すれば、そこから lab.local を引く (クラウド→オンプレ方向の実テスト)
$spokeVmExists = az vm show -g rg-spoke1 -n vm-spoke1-web --query "name" -o tsv 2>$null
if ($spokeVmExists) {
    Write-Host "  vm-spoke1-web から $adDomain の名前解決を確認..." -ForegroundColor Gray

    $spokeResolveOut = Invoke-VmCommand 'rg-spoke1' 'vm-spoke1-web' @"
`$r = Resolve-DnsName '$adDomain' -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('SPOKE_AD_RESOLVE=' + `$(if (`$r) {'OK'} else {'NG'}))
`$dc = Resolve-DnsName 'DC01.$adDomain' -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('SPOKE_DC_RESOLVE=' + `$(if (`$dc) { `$dc[0].IPAddress } else {'NG'}))
"@

    Test-Val      "vm-spoke1-web → $adDomain 解決"       (Get-Val $spokeResolveOut 'SPOKE_AD_RESOLVE') 'OK'
    Test-NotEmpty "vm-spoke1-web → DC01.$adDomain 解決"   (Get-Val $spokeResolveOut 'SPOKE_DC_RESOLVE')
} else {
    Write-Host "  vm-spoke1-web が未作成のため、Spoke→オンプレ方向のテストはスキップ" -ForegroundColor DarkGray
}

# ============================================================
# 7. VPN 経由の基本疎通 (オンプレ → Hub)
# ============================================================
Write-Host "`n=== 7. VPN 経由の基本疎通 ===" -ForegroundColor Cyan
Write-Host "  DC01 から Hub ネットワークへの疎通確認..." -ForegroundColor Gray

$vpnOut = Invoke-VmCommand $OnpremResourceGroup 'vm-onprem-ad' @'
$p1 = Test-NetConnection -ComputerName 10.10.5.4 -WarningAction SilentlyContinue
Write-Output ('HUB_DNS_PING=' + $p1.PingSucceeded)
$p2 = Test-NetConnection -ComputerName 10.10.1.4 -WarningAction SilentlyContinue
Write-Output ('HUB_FW_PING=' + $p2.PingSucceeded)
'@

# Firewall は ICMP をブロックする可能性があるため info 扱い
$hubDnsPing = Get-Val $vpnOut 'HUB_DNS_PING'
$hubFwPing  = Get-Val $vpnOut 'HUB_FW_PING'
Test-Val 'DC01 → Hub DNS (10.10.5.4) ICMP' $hubDnsPing 'True'
Write-Host "         DC01 → Hub FW  (10.10.1.4) ICMP: $hubFwPing (Firewall は ICMP ブロックの場合あり)" -ForegroundColor Gray

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}
