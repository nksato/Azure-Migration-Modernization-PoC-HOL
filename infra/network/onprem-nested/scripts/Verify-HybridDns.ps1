<#
.SYNOPSIS
    Nested Hyper-V 環境のハイブリッド DNS 構成を検証する
.DESCRIPTION
    Setup-HybridDns.ps1 で構成した DNS 設定の状態と名前解決を検証する。
    ローカル PC から Azure CLI + az vm run-command で実行する。

    検証項目:
      1. DNS Private Resolver (dnspr-hub) 状態
      2. DNS Forwarding Ruleset (frs-onprem) — contoso.local -> Host IP
      3. Hyper-V ホスト DNS Server + 条件付きフォワーダー
      4. vm-ad01 条件付きフォワーダー (privatelink.* -> Hub DNS Resolver)
      5. 名前解決: Host -> contoso.local (Host -> vm-ad01)
      6. 名前解決: vm-ad01 -> privatelink.* (On-prem -> Cloud)
      7. 名前解決: vm-app01 -> privatelink.* (End-to-End)
      8. オプション: EnableCloudVmResolution (azure.internal)

    前提:
      - Azure CLI ログイン済み (az login)
      - VPN 接続確立済み (onprem-nested <-> Hub)
      - ローカル PC から実行
.EXAMPLE
    .\Verify-HybridDns.ps1
.EXAMPLE
    .\Verify-HybridDns.ps1 -EnableCloudVmResolution
#>

[CmdletBinding()]
param(
    [string]$HubResourceGroup = 'rg-hub',
    [string]$OnpremResourceGroup = 'rg-onprem-nested',
    [string]$HubDnsResolverName = 'dnspr-hub',
    [string]$HostVmName = 'vm-onprem-nested-hv01',
    [string]$DomainName = 'contoso.local',
    [string]$DcIp = '192.168.100.10',
    [string]$RulesetName = 'frs-onprem',
    [switch]$EnableCloudVmResolution
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# --- ヘルパー ---

function Invoke-HostCommand ([string]$Script) {
    $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
    try {
        $Script | Set-Content -Path $tmpFile -Encoding UTF8
        $json = az vm run-command invoke `
            --resource-group $OnpremResourceGroup --name $HostVmName `
            --command-id RunPowerShellScript --scripts "@$tmpFile" -o json 2>$null
        if (-not $json) { return '' }
        $r = ($json -join '') | ConvertFrom-Json
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

# Hyper-V ホスト IP を取得 (転送先の期待値)
$hostPrivateIp = az vm list-ip-addresses `
    -g $OnpremResourceGroup -n $HostVmName `
    --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv 2>$null

# 転送ルール
$ruleName = ($DomainName -replace '\.', '-')
$rulesJson = az dns-resolver forwarding-rule list -g $HubResourceGroup --ruleset-name $RulesetName `
    --query "[].{name:name, domain:domainName, state:forwardingRuleState, target:targetDnsServers[0].ipAddress}" `
    -o json 2>$null
if ($rulesJson) {
    $rules = $rulesJson | ConvertFrom-Json
    $domainRule = $rules | Where-Object { $_.domain -match [regex]::Escape($DomainName) }
    if ($domainRule) {
        Test-Val  '転送ルール状態'        $domainRule.state  'Enabled'
        if ($hostPrivateIp) {
            Test-Val  "転送先 (Host IP)"  $domainRule.target $hostPrivateIp
        } else {
            Test-NotEmpty '転送先 IP'     $domainRule.target
        }
        Write-Host "         ドメイン: $($domainRule.domain)" -ForegroundColor Gray
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
Test-Bool "Ruleset VNet リンク数 >= 1 (Hub 必須) (実際: $vnetLinkCount)" ($vnetLinkCount -ge 1)
if ($vnetLinks) {
    foreach ($link in $vnetLinks) {
        $vnetName = ($link.virtualNetwork.id -split '/')[-1]
        Write-Host "         $($link.name) -> $vnetName" -ForegroundColor Gray
    }
}

# ============================================================
# 3. Hyper-V ホスト DNS Server + 条件付きフォワーダー
# ============================================================
Write-Host "`n=== 3. Hyper-V ホスト DNS Server ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

$hostDnsOut = Invoke-HostCommand @"
`$dns = Get-WindowsFeature DNS
Write-Output ('DNS_INSTALLED=' + `$dns.Installed)
`$z = Get-DnsServerZone -Name '$DomainName' -ErrorAction SilentlyContinue
if (`$z) {
    Write-Output ('HOST_ZONE_TYPE=' + `$z.ZoneType)
    Write-Output ('HOST_MASTER_SERVERS=' + (`$z.MasterServers -join ','))
} else {
    Write-Output 'HOST_ZONE_TYPE='
    Write-Output 'HOST_MASTER_SERVERS='
}
"@

$dnsInstalled = Get-Val $hostDnsOut 'DNS_INSTALLED'
Test-Val 'DNS Server ロール' $dnsInstalled 'True'

$hostZoneType = Get-Val $hostDnsOut 'HOST_ZONE_TYPE'
$hostMasters  = Get-Val $hostDnsOut 'HOST_MASTER_SERVERS'
Test-Val      "条件付きフォワーダー ($DomainName)" $hostZoneType 'Forwarder'
Test-Val      "転送先 (vm-ad01 IP)"               $hostMasters  $DcIp

# ============================================================
# 4. vm-ad01 条件付きフォワーダー (オンプレ → クラウド)
# ============================================================
Write-Host "`n=== 4. vm-ad01 条件付きフォワーダー (privatelink.*) ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中 (PowerShell Direct)..." -ForegroundColor Gray

$privateLinkZones = @(
    'privatelink.database.windows.net'
    'privatelink.blob.core.windows.net'
    'privatelink.vaultcore.azure.net'
    'privatelink.azurewebsites.net'
)

$adFwdOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
    $zones = Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' }
    foreach ($z in $zones) {
        Write-Output ("ZONE=$($z.ZoneName)|TYPE=$($z.ZoneType)|MASTERS=$($z.MasterServers -join ',')")
    }
}
'@

foreach ($zone in $privateLinkZones) {
    $line = ($adFwdOut -split "`n") | Where-Object { $_ -match "ZONE=$([regex]::Escape($zone))" } | Select-Object -First 1
    if ($line -and $line -match 'MASTERS=(.+)') {
        $masters = $Matches[1].Trim()
        $matchIp = $masters -match [regex]::Escape($inboundIp)
        Test-Bool "$zone -> $masters (Inbound IP 一致: $matchIp)" $matchIp
    } else {
        Test-Bool "$zone 条件付きフォワーダー" $false
    }
}

# ============================================================
# 5. 名前解決: Host -> contoso.local
# ============================================================
Write-Host "`n=== 5. 名前解決: Host -> $DomainName ===" -ForegroundColor Cyan
Write-Host "  Host から名前解決テスト実行中..." -ForegroundColor Gray

$hostResolveOut = Invoke-HostCommand @"
`$r = Resolve-DnsName -Name '$DomainName' -DnsOnly -ErrorAction SilentlyContinue
if (`$r) { Write-Output ('HOST_RESOLVE=OK:' + `$r[0].IPAddress) } else { Write-Output 'HOST_RESOLVE=FAIL' }
"@

$hostResolveResult = Get-Val $hostResolveOut 'HOST_RESOLVE'
if ($hostResolveResult -like 'OK:*') {
    $resolvedIp = $hostResolveResult -replace '^OK:', ''
    Test-Bool "Host -> $DomainName 解決: $resolvedIp" $true
} else {
    Test-Bool "Host -> $DomainName 解決" $false
    Write-Host '         ※ Host の DNS Server ロールまたは条件付きフォワーダーを確認してください' -ForegroundColor Yellow
}

# ============================================================
# 6. 名前解決: vm-ad01 -> privatelink.* (オンプレ → クラウド)
# ============================================================
Write-Host "`n=== 6. 名前解決: vm-ad01 -> privatelink.* ===" -ForegroundColor Cyan
Write-Host "  vm-ad01 から名前解決テスト実行中 (PowerShell Direct)..." -ForegroundColor Gray

$adResolveOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
    $r1 = Resolve-DnsName 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
    Write-Output ('AD_PLINK_DB=' + $(if ($r1) {'OK'} else {'NG'}))
    $r2 = Resolve-DnsName 'privatelink.blob.core.windows.net' -DnsOnly -ErrorAction SilentlyContinue
    Write-Output ('AD_PLINK_BLOB=' + $(if ($r2) {'OK'} else {'NG'}))
}
'@

$adPlinkDb   = Get-Val $adResolveOut 'AD_PLINK_DB'
$adPlinkBlob = Get-Val $adResolveOut 'AD_PLINK_BLOB'

# privatelink ゾーンは Private DNS Zone にレコードがなくても SOA が返る場合 OK
$dbColor = if ($adPlinkDb -eq 'OK') { 'OK' } else { 'NG (PE 未作成の場合は想定内)' }
$blobColor = if ($adPlinkBlob -eq 'OK') { 'OK' } else { 'NG (PE 未作成の場合は想定内)' }

if ($adPlinkDb -eq 'OK') {
    Test-Bool "vm-ad01 -> privatelink.database.windows.net: OK" $true
} else {
    Write-Host "  [WARN] vm-ad01 -> privatelink.database.windows.net: $dbColor" -ForegroundColor Yellow
    $script:total++
}

if ($adPlinkBlob -eq 'OK') {
    Test-Bool "vm-ad01 -> privatelink.blob.core.windows.net: OK" $true
} else {
    Write-Host "  [WARN] vm-ad01 -> privatelink.blob.core.windows.net: $blobColor" -ForegroundColor Yellow
    $script:total++
}

if ($adPlinkDb -ne 'OK' -and $adPlinkBlob -ne 'OK') {
    Write-Host '         ※ VPN 接続と vm-ad01 の条件付きフォワーダーを確認してください' -ForegroundColor Yellow
}

# ============================================================
# 7. 名前解決: vm-app01 -> privatelink.* (End-to-End)
# ============================================================
Write-Host "`n=== 7. 名前解決: vm-app01 -> privatelink.* (End-to-End) ===" -ForegroundColor Cyan
Write-Host "  vm-app01 から名前解決テスト実行中 (PowerShell Direct)..." -ForegroundColor Gray

$appResolveOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
Invoke-Command -VMName 'vm-app01' -Credential $cred -ScriptBlock {
    $r = Resolve-DnsName 'privatelink.database.windows.net' -DnsOnly -ErrorAction SilentlyContinue
    Write-Output ('APP_PLINK_DB=' + $(if ($r) {'OK'} else {'NG'}))
    $r2 = Resolve-DnsName 'contoso.local' -DnsOnly -ErrorAction SilentlyContinue
    Write-Output ('APP_DOMAIN=' + $(if ($r2) {'OK'} else {'NG'}))
}
'@

$appPlinkDb = Get-Val $appResolveOut 'APP_PLINK_DB'
$appDomain  = Get-Val $appResolveOut 'APP_DOMAIN'

Test-Val 'vm-app01 -> contoso.local 解決' $appDomain 'OK'

if ($appPlinkDb -eq 'OK') {
    Test-Bool "vm-app01 -> privatelink.database.windows.net (E2E): OK" $true
} else {
    Write-Host "  [WARN] vm-app01 -> privatelink.database.windows.net (E2E): NG (PE 未作成の場合は想定内)" -ForegroundColor Yellow
    $script:total++
}
Write-Host "         経路: vm-app01 -> vm-ad01 (DNS) -> VPN -> Hub DNS Resolver ($inboundIp) -> Private DNS Zone" -ForegroundColor Gray

# ============================================================
# 8. 名前解決: クラウド -> オンプレ (DNS Resolver 経由)
# ============================================================
Write-Host "`n=== 8. 名前解決: クラウド -> $DomainName ===" -ForegroundColor Cyan

# Host から DNS Resolver Inbound IP を -Server 指定して
# Forwarding Ruleset -> Outbound -> Host -> vm-ad01 のチェーンを検証
Write-Host "  Host -> DNS Resolver 経由で $DomainName を検証中..." -ForegroundColor Gray

$cloudResolveOut = Invoke-HostCommand @"
`$r = Resolve-DnsName '$DomainName' -Server '$inboundIp' -DnsOnly -ErrorAction SilentlyContinue
if (`$r) { Write-Output ('CLOUD_RESOLVE=OK:' + `$r[0].IPAddress) } else { Write-Output 'CLOUD_RESOLVE=FAIL' }
"@

$cloudResolveResult = Get-Val $cloudResolveOut 'CLOUD_RESOLVE'
if ($cloudResolveResult -like 'OK:*') {
    $resolvedIp = $cloudResolveResult -replace '^OK:', ''
    Test-Bool "DNS Resolver -> $DomainName 解決: $resolvedIp" $true
} else {
    Test-Bool "DNS Resolver -> $DomainName 解決" $false
    Write-Host '         ※ Forwarding Ruleset のルールと VNet リンクを確認してください' -ForegroundColor Yellow
}
Write-Host "         経路: DNS Resolver ($inboundIp) -> Outbound -> Ruleset ($RulesetName) -> VPN -> Host -> vm-ad01" -ForegroundColor Gray

# ============================================================
# 9. オプション: EnableCloudVmResolution (azure.internal)
# ============================================================
Write-Host "`n=== 9. オプション: EnableCloudVmResolution ===" -ForegroundColor Cyan

if (-not $EnableCloudVmResolution) {
    Write-Host "  スキップ (-EnableCloudVmResolution 未指定)" -ForegroundColor DarkGray
} else {
    $cloudVmDnsZone = 'azure.internal'

    $azInternalState = az network private-dns zone show -g $HubResourceGroup -n $cloudVmDnsZone `
        --query "provisioningState" -o tsv 2>$null

    if ($azInternalState) {
        Test-Val "$cloudVmDnsZone ゾーン プロビジョニング" $azInternalState 'Succeeded'

        # VNet リンク数
        $zoneLinksJson = az network private-dns link vnet list -g $HubResourceGroup -z $cloudVmDnsZone `
            -o json 2>$null
        $zoneLinks = if ($zoneLinksJson) { $zoneLinksJson | ConvertFrom-Json } else { @() }
        $zoneLinkCount = if ($zoneLinks) { $zoneLinks.Count } else { 0 }
        Test-Bool "$cloudVmDnsZone VNet リンク数 >= 1 (実際: $zoneLinkCount)" ($zoneLinkCount -ge 1)
        if ($zoneLinks) {
            foreach ($zl in $zoneLinks) {
                $vn = ($zl.virtualNetwork.id -split '/')[-1]
                $reg = if ($zl.registrationEnabled) { '自動登録:有効' } else { '自動登録:無効' }
                Write-Host "         $($zl.name) -> $vn ($reg)" -ForegroundColor Gray
            }
        }

        # vm-ad01 条件付きフォワーダー (azure.internal)
        Write-Host "  vm-ad01 の $cloudVmDnsZone 条件付きフォワーダーを確認中..." -ForegroundColor Gray

        $azFwdOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
    $z = Get-DnsServerZone -Name 'azure.internal' -ErrorAction SilentlyContinue
    if ($z) { Write-Output ('AZ_ZONE_TYPE=' + $z.ZoneType); Write-Output ('AZ_MASTERS=' + ($z.MasterServers -join ',')) }
    else { Write-Output 'AZ_ZONE_TYPE='; Write-Output 'AZ_MASTERS=' }
}
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
        Write-Host "  スキップ: $cloudVmDnsZone ゾーン未検出 (Setup-HybridDns.ps1 -EnableCloudVmResolution 未実行)" -ForegroundColor DarkGray
    }
}

# ============================================================
# 設定情報サマリ
# ============================================================
Write-Host "`n=== 設定情報サマリ ===" -ForegroundColor Cyan
Write-Host "  DNS Resolver Inbound IP  : $inboundIp" -ForegroundColor Gray
Write-Host "  Forwarding Ruleset       : $RulesetName" -ForegroundColor Gray
Write-Host "  転送ルール (-> オンプレ)  : $DomainName -> $hostPrivateIp (Host)" -ForegroundColor Gray
Write-Host "  Host フォワーダー        : $DomainName -> $DcIp (vm-ad01)" -ForegroundColor Gray
Write-Host "  vm-ad01 フォワーダー     : privatelink.* -> $inboundIp (DNS Resolver)" -ForegroundColor Gray

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] / [WARN] を確認してください。" -ForegroundColor Yellow
    Write-Host "  privatelink.* の名前解決失敗は、Private Endpoint 未作成の場合は想定内です。" -ForegroundColor Yellow
}
