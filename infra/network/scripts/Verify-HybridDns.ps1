<#
.SYNOPSIS
    ハイブリッド DNS 構成の状態と双方向疎通を検証する
.DESCRIPTION
    Azure CLI と az vm run-command で DNS 設定状態・名前解決を確認する。
    Azure API + VM 内の DNS 解決結果で判定する簡易チェック。
    ブラウザやポータル画面での目視確認は含まない。
.EXAMPLE
    .\Verify-HybridDns.ps1
.EXAMPLE
    .\Verify-HybridDns.ps1 -EnableCloudVmResolution -LinkSpokeVnets
#>

[CmdletBinding()]
param(
    [string]$OnpremResourceGroup = 'rg-onprem',
    [string]$HubResourceGroup = 'rg-hub',
    [string]$HubDnsResolverName = 'dnspr-hub',
    [string]$RulesetName = 'frs-hub',
    [string]$OnpremVmName = 'vm-onprem-ad',
    [string]$DomainName = 'lab.local',
    [string]$DcIp = '10.0.1.4',
    [switch]$EnableCloudVmResolution,
    [switch]$LinkSpokeVnets
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# --- ヘルパー ---

function Invoke-VmCommand ([string]$ResourceGroup, [string]$VmName, [string]$Script) {
    $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
    try {
        $Script | Set-Content -Path $tmpFile -Encoding UTF8
        $json = az vm run-command invoke `
            --resource-group $ResourceGroup --name $VmName `
            --command-id RunPowerShellScript --scripts "@$tmpFile" -o json 2>&1
        $r = ($json | Where-Object { $_ -is [string] }) -join '' | ConvertFrom-Json
        $stderr = ($r.value | Where-Object { $_.code -like '*stderr*' }).message
        if ($stderr) { Write-Host "         stderr: $stderr" -ForegroundColor DarkYellow }
        ($r.value | Where-Object { $_.code -like '*stdout*' }).message
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
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

$resolverState = az dns-resolver show -g $HubResourceGroup -n $HubDnsResolverName `
    --query "provisioningState" -o tsv 2>$null
Test-Val "$HubDnsResolverName プロビジョニング" $resolverState 'Succeeded'

$inboundIp = az dns-resolver inbound-endpoint show -g $HubResourceGroup `
    --dns-resolver-name $HubDnsResolverName --name inbound `
    --query "ipConfigurations[0].privateIpAddress" -o tsv 2>$null
Test-NotEmpty 'Inbound Endpoint IP' $inboundIp

$outboundState = az dns-resolver outbound-endpoint show -g $HubResourceGroup `
    --dns-resolver-name $HubDnsResolverName --name outbound `
    --query "provisioningState" -o tsv 2>$null
Test-Val 'Outbound Endpoint' $outboundState 'Succeeded'

# ============================================================
# 2. DNS Forwarding Ruleset (クラウド → オンプレ)
# ============================================================
Write-Host "`n=== 2. DNS Forwarding Ruleset (クラウド → オンプレ) ===" -ForegroundColor Cyan

$rulesetState = az dns-resolver forwarding-ruleset show -g $HubResourceGroup -n $RulesetName `
    --query "provisioningState" -o tsv 2>$null
Test-Val "$RulesetName プロビジョニング" $rulesetState 'Succeeded'

# 転送ルール一覧を取得
$rulesJson = az dns-resolver forwarding-rule list -g $HubResourceGroup --ruleset-name $RulesetName `
    --query "[].{name:name, domain:domainName, state:forwardingRuleState, target:targetDnsServers[0].ipAddress}" `
    -o json 2>$null
if ($rulesJson) {
    $rules = $rulesJson | ConvertFrom-Json
    $domainPattern = [regex]::Escape($DomainName)
    $labRule = $rules | Where-Object { $_.domain -match $domainPattern }
    if ($labRule) {
        Test-Val  '転送ルール状態'         $labRule.state  'Enabled'
        Test-Val  "転送先 ($OnpremVmName)" $labRule.target $DcIp
        Write-Host "         ドメイン: $($labRule.domain)" -ForegroundColor Gray
    } else {
        Test-Val "$DomainName 転送ルール" '(未検出)' 'Enabled'
    }
} else {
    Test-Val "$RulesetName 転送ルール" '(未検出)' 'Enabled'
}

# VNet リンク
$vnetLinks = az dns-resolver vnet-link list --ruleset-name $RulesetName `
    --resource-group $HubResourceGroup -o json 2>$null | ConvertFrom-Json
$vnetLinkCount = if ($vnetLinks) { $vnetLinks.Count } else { 0 }
Test-Bool "Ruleset VNet リンク数 >= 1 (Hub 必須、Spoke は -LinkSpokeVnets で追加) (実際: $vnetLinkCount)" ($vnetLinkCount -ge 1)
if ($vnetLinks) {
    foreach ($link in $vnetLinks) {
        $vnetName = ($link.virtualNetwork.id -split '/')[-1]
        Write-Host "         $($link.name) → $vnetName" -ForegroundColor Gray
    }
}

# ============================================================
# 3. DC01 条件付きフォワーダー (オンプレ → クラウド)
# ============================================================
Write-Host "`n=== 3. DC01 条件付きフォワーダー (オンプレ → クラウド) ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

$privateLinkZones = @(
    'privatelink.database.windows.net'
    # 'privatelink.blob.core.windows.net'     # Spoke3/4 展開時に有効化
    # 'privatelink.vaultcore.azure.net'        # Spoke3/4 展開時に有効化
    # 'privatelink.azurewebsites.net'          # Spoke4 展開時に有効化
)

$fwdOut = Invoke-VmCommand $OnpremResourceGroup $OnpremVmName @'
$zones = Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' }
foreach ($z in $zones) {
    Write-Output ("ZONE=$($z.ZoneName)|TYPE=$($z.ZoneType)|MASTERS=$($z.MasterServers -join ',')")
}
'@

foreach ($zone in $privateLinkZones) {
    $line = ($fwdOut -split "`n") | Where-Object { $_ -match "ZONE=$([regex]::Escape($zone))" } | Select-Object -First 1
    if ($line -and $line -match 'MASTERS=(.+)') {
        $masters = $Matches[1].Trim()
        $matchIp = $masters -match [regex]::Escape($inboundIp)
        Test-Bool "$zone -> $masters (Inbound IP 一致: $matchIp)" $matchIp
    } else {
        Test-Bool "$zone 条件付きフォワーダー" $false
    }
}

# ============================================================
# 4. 名前解決: オンプレ → クラウド
# ============================================================
Write-Host "`n=== 4. 名前解決: オンプレ → クラウド ===" -ForegroundColor Cyan
Write-Host "  $OnpremVmName から名前解決テスト実行中..." -ForegroundColor Gray

$resolveOut = Invoke-VmCommand $OnpremResourceGroup $OnpremVmName @'
$r1 = Resolve-DnsName 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('PLINK_RESOLVE=' + $(if ($r1) {'OK'} else {'NG'}))
'@

$plinkResult = Get-Val $resolveOut 'PLINK_RESOLVE'
Test-Val "$OnpremVmName → privatelink.database.windows.net 解決" $plinkResult 'OK'
if ($plinkResult -ne 'OK') {
    Write-Host '         ※ 名前解決に失敗した場合、まず IP アドレスを用いて到達性を確認してください' -ForegroundColor Yellow
}

# ============================================================
# 5. 名前解決: クラウド → オンプレ
# ============================================================
Write-Host "`n=== 5. 名前解決: クラウド → オンプレ ===" -ForegroundColor Cyan

# OnPrem VM から DNS Resolver Inbound IP を -Server 指定して
# Forwarding Ruleset → Outbound → OnPrem DC のチェーンが動作するかを検証
Write-Host "  $OnpremVmName → DNS Resolver 経由で検証中..." -ForegroundColor Gray

$fallbackOut = Invoke-VmCommand $OnpremResourceGroup $OnpremVmName @"
`$r = Resolve-DnsName '$DomainName' -Server '$inboundIp' -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('FALLBACK_RESOLVE=' + `$(if (`$r) {'OK'} else {'NG'}))
"@

$fallbackResult = Get-Val $fallbackOut 'FALLBACK_RESOLVE'
Test-Val "$OnpremVmName → $DomainName (-Server DNS Resolver) 解決" $fallbackResult 'OK'
Write-Host "         経路: $OnpremVmName → DNS Resolver ($inboundIp) → Forwarding Ruleset → Outbound → DC" -ForegroundColor Gray
if ($fallbackResult -ne 'OK') {
    Write-Host '         ※ 名前解決に失敗した場合、まず IP アドレスを用いて到達性を確認してください' -ForegroundColor Yellow
}

# ============================================================
# 6. オプション検証: EnableCloudVmResolution (azure.internal)
# ============================================================
Write-Host "`n=== 6. オプション検証: EnableCloudVmResolution ===" -ForegroundColor Cyan

if (-not $EnableCloudVmResolution) {
    Write-Host "  スキップ (-EnableCloudVmResolution 未指定)" -ForegroundColor DarkGray
} else {

$azInternalState = az network private-dns zone show -g $HubResourceGroup -n 'azure.internal' `
    --query "provisioningState" -o tsv 2>$null

if ($azInternalState) {
    Test-Val 'azure.internal ゾーン プロビジョニング' $azInternalState 'Succeeded'

    # VNet リンク数
    $zoneLinksJson = az network private-dns link vnet list -g $HubResourceGroup -z 'azure.internal' `
        -o json 2>$null
    $zoneLinks = if ($zoneLinksJson) { $zoneLinksJson | ConvertFrom-Json } else { @() }
    $zoneLinkCount = if ($zoneLinks) { $zoneLinks.Count } else { 0 }
    Test-Bool "azure.internal VNet リンク数 >= 1 (実際: $zoneLinkCount)" ($zoneLinkCount -ge 1)
    if ($zoneLinks) {
        foreach ($zl in $zoneLinks) {
            $vn = ($zl.virtualNetwork.id -split '/')[-1]
            $reg = if ($zl.registrationEnabled) { '自動登録:有効' } else { '自動登録:無効' }
            Write-Host "         $($zl.name) → $vn ($reg)" -ForegroundColor Gray
        }
    }

    # DC01 条件付きフォワーダー (azure.internal)
    Write-Host "  $OnpremVmName の azure.internal 条件付きフォワーダーを確認中..." -ForegroundColor Gray

    $azFwdOut = Invoke-VmCommand $OnpremResourceGroup $OnpremVmName @'
$z = Get-DnsServerZone -Name 'azure.internal' -ErrorAction SilentlyContinue
if ($z) { Write-Output ('AZ_ZONE_TYPE=' + $z.ZoneType); Write-Output ('AZ_MASTERS=' + ($z.MasterServers -join ',')) } else { Write-Output 'AZ_ZONE_TYPE='; Write-Output 'AZ_MASTERS=' }
'@

    $azZoneType = Get-Val $azFwdOut 'AZ_ZONE_TYPE'
    $azMasters  = Get-Val $azFwdOut 'AZ_MASTERS'
    Test-Val '条件付きフォワーダー種別 (azure.internal)' $azZoneType 'Forwarder'
    if ($inboundIp -and $azMasters) {
        Test-Bool "転送先が Inbound IP ($inboundIp) と一致" ($azMasters -match [regex]::Escape($inboundIp))
    } else {
        Test-Bool "転送先が Inbound IP と一致 (azure.internal)" $false
    }
} else {
    Write-Host "  スキップ: azure.internal ゾーン未検出 (-EnableCloudVmResolution 未実行)" -ForegroundColor DarkGray
}

} # -EnableCloudVmResolution guard

# ============================================================
# 7. オプション検証: LinkSpokeVnets (Forwarding Ruleset)
# ============================================================
Write-Host "`n=== 7. オプション検証: LinkSpokeVnets ===" -ForegroundColor Cyan

if (-not $LinkSpokeVnets) {
    Write-Host "  スキップ (-LinkSpokeVnets 未指定)" -ForegroundColor DarkGray
} else {

$rulesetLinksJson = az dns-resolver vnet-link list --ruleset-name $RulesetName `
    --resource-group $HubResourceGroup -o json 2>$null
$rulesetLinks = if ($rulesetLinksJson) { $rulesetLinksJson | ConvertFrom-Json } else { @() }
$rulesetLinkCount = if ($rulesetLinks) { $rulesetLinks.Count } else { 0 }

if ($rulesetLinkCount -ge 2) {
    # Hub + Spoke が紐付いている → -LinkSpokeVnets 実行済み
    Test-Bool "Ruleset VNet リンク数 >= 2 (Hub + Spoke) (実際: $rulesetLinkCount)" $true

    $spokeOnlyLinks = $rulesetLinks | Where-Object { ($_.virtualNetwork.id -split '/')[-1] -ne 'vnet-hub' }
    foreach ($sl in $spokeOnlyLinks) {
        $svn = ($sl.virtualNetwork.id -split '/')[-1]
        Write-Host "         Spoke リンク: $($sl.name) → $svn" -ForegroundColor Gray
    }
} else {
    Write-Host "  スキップ: Spoke VNet リンク未検出 (-LinkSpokeVnets 未実行)" -ForegroundColor DarkGray
}

# Spoke VM が存在すれば lab.local 名前解決テスト
$spokeVmExists = az vm show -g rg-spoke1 -n vm-spoke1-web --query "name" -o tsv 2>$null
if ($spokeVmExists) {
    Write-Host "  vm-spoke1-web から lab.local の名前解決を確認..." -ForegroundColor Gray

    $spokeResolveOut = Invoke-VmCommand 'rg-spoke1' 'vm-spoke1-web' @'
$r = Resolve-DnsName 'lab.local' -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('SPOKE_AD_RESOLVE=' + $(if ($r) {'OK'} else {'NG'}))
$dc = Resolve-DnsName 'DC01.lab.local' -DnsOnly -ErrorAction SilentlyContinue
Write-Output ('SPOKE_DC_RESOLVE=' + $(if ($dc) { $dc[0].IPAddress } else {'NG'}))
'@

    $spokeAdResult = Get-Val $spokeResolveOut 'SPOKE_AD_RESOLVE'
    $spokeDcResult = Get-Val $spokeResolveOut 'SPOKE_DC_RESOLVE'
    Test-Val      'vm-spoke1-web → lab.local 解決'       $spokeAdResult 'OK'
    Test-Val      'vm-spoke1-web → DC01.lab.local 解決'  $spokeDcResult $DcIp
    if ($spokeAdResult -ne 'OK' -or $spokeDcResult -ne $DcIp) {
        Write-Host '         ※ 名前解決に失敗した場合、まず IP アドレスを用いて到達性を確認してください' -ForegroundColor Yellow
    }
} else {
    Write-Host "  [SKIP] Spoke VM (vm-spoke1-web) 未デプロイ — 名前解決テストスキップ" -ForegroundColor DarkGray
}

} # -LinkSpokeVnets guard

# ============================================================
# 設定情報サマリ
# ============================================================
Write-Host "`n=== 設定情報サマリ ===" -ForegroundColor Cyan
Write-Host "  DNS Resolver Inbound IP  : $inboundIp" -ForegroundColor Gray
Write-Host "  Forwarding Ruleset       : $RulesetName" -ForegroundColor Gray
Write-Host "  転送ルール (→ オンプレ)  : $DomainName → $DcIp" -ForegroundColor Gray
Write-Host "  条件付きフォワーダー     : privatelink.* → $inboundIp (DNS Resolver)" -ForegroundColor Gray

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}
