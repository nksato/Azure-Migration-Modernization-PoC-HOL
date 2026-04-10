<#
.SYNOPSIS
    疑似オンプレ環境のセットアップ状態をリモートから検証する
.DESCRIPTION
    az vm run-command invoke で各 VM から値を取得し、ローカルで判定する。
    リモート側は Write-Output ('KEY=' + (値取得コマンド)) で出力するだけの
    シンプルな設計。Bastion 接続不要。
.EXAMPLE
    .\Verify-OnpremSetup.ps1
    .\Verify-OnpremSetup.ps1 -SkipPartsUnlimited
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-onprem',
    [switch]$SkipPartsUnlimited
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# --- ヘルパー ---

function Invoke-VmCommand ([string]$VmName, [string]$Script) {
    $oneLiner = ($Script -split "`r?`n" | Where-Object { $_.Trim() }) -join '; '
    $json = az vm run-command invoke `
        --resource-group $ResourceGroupName --name $VmName `
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

function Test-Match ([string]$Label, [string]$Actual, [string]$Pattern) {
    $ok = $Actual -match $Pattern
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

# ============================================================
# 1. リソースグループ & 共通リソース
# ============================================================
Write-Host "`n=== 1. リソースグループ & 共通リソース ===" -ForegroundColor Cyan

$rgExists = az group exists -n $ResourceGroupName -o tsv 2>$null
Test-Val $ResourceGroupName $rgExists 'true'

if ($rgExists -ne 'true') {
    Write-Host "`n  リソースグループが見つかりません。デプロイを確認してください。" -ForegroundColor Red
    Write-Host ("`n結果: {0}/{1} PASS" -f $passed, $total) -ForegroundColor $(if ($passed -eq $total) {'Green'} else {'Yellow'})
    exit 1
}

$bastionState = az network bastion show -g $ResourceGroupName -n 'bas-onprem' `
    --query provisioningState -o tsv 2>$null
Test-Val 'bas-onprem (Bastion)' $bastionState 'Succeeded'

$natGwState = az network nat gateway show -g $ResourceGroupName -n 'ng-onprem' `
    --query provisioningState -o tsv 2>$null
Test-Val 'ng-onprem (NAT Gateway)' $natGwState 'Succeeded'

# ============================================================
# 2. VNet & サブネット
# ============================================================
Write-Host "`n=== 2. VNet & サブネット ===" -ForegroundColor Cyan

$vnetAddr = az network vnet show -g $ResourceGroupName -n vnet-onprem `
    --query "addressSpace.addressPrefixes[0]" -o tsv 2>$null
Test-Val 'vnet-onprem' $vnetAddr '10.0.0.0/16'

foreach ($snet in @('snet-onprem', 'AzureBastionSubnet')) {
    $prefix = az network vnet subnet show -g $ResourceGroupName --vnet-name vnet-onprem -n $snet `
        --query "addressPrefix" -o tsv 2>$null
    Test-NotEmpty "vnet-onprem/$snet" $prefix
}

# ============================================================
# 3. VM の状態 & パブリック IP なし
# ============================================================
Write-Host "`n=== 3. VM の状態 ===" -ForegroundColor Cyan

foreach ($vm in @('vm-onprem-ad', 'vm-onprem-sql', 'vm-onprem-web')) {
    $st = az vm get-instance-view -g $ResourceGroupName -n $vm `
        --query "instanceView.statuses[?code=='PowerState/running'].displayStatus | [0]" -o tsv 2>$null
    Test-Val $vm $st 'VM running'
}

foreach ($nic in @('nic-vm-onprem-ad', 'nic-vm-onprem-sql', 'nic-vm-onprem-web')) {
    $pip = az network nic show -g $ResourceGroupName -n $nic `
        --query "ipConfigurations[].publicIPAddress.id" -o tsv 2>$null
    $hasPip = -not [string]::IsNullOrWhiteSpace($pip)
    $color = if ($hasPip) { 'Red' } else { 'Green' }
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($hasPip) {'FAIL'} else {'PASS'}), $nic, $(if ($hasPip) {$pip} else {'PIP なし'})) -ForegroundColor $color
    $total++; if (-not $hasPip) { $passed++ }
}

# ============================================================
# 4. DC01: Active Directory + DNS
# ============================================================
Write-Host "`n=== 4. DC01: Active Directory + DNS ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

$dcOut = Invoke-VmCommand 'vm-onprem-ad' @'
$d = Get-ADDomain
Write-Output ('DOMAIN=' + $d.DNSRoot)
Write-Output ('PDC=' + $d.PDCEmulator)
$z = Get-DnsServerZone -Name $d.DNSRoot -ErrorAction SilentlyContinue
Write-Output ('DNSZONE=' + $z.ZoneName)
'@

$script:adDomain = Get-Val $dcOut 'DOMAIN'
Test-NotEmpty 'AD ドメイン'   $adDomain
Test-Val      'DNS ゾーン'    (Get-Val $dcOut 'DNSZONE') $adDomain
Test-NotEmpty 'PDC Emulator' (Get-Val $dcOut 'PDC')

# ============================================================
# 5. DB01: SQL Server + ドメイン参加
# ============================================================
Write-Host "`n=== 5. DB01: SQL Server + ドメイン参加 ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

$dbOut = Invoke-VmCommand 'vm-onprem-sql' @'
$cs = Get-WmiObject Win32_ComputerSystem
Write-Output ('PART_OF_DOMAIN=' + $cs.PartOfDomain)
Write-Output ('DOMAIN=' + $cs.Domain)
Write-Output ('SQL_SVC=' + (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status)
Write-Output ('DATA_DRIVE=' + (Test-Path F:\SQLData))
'@

Test-Val 'SQL Server サービス'       (Get-Val $dbOut 'SQL_SVC')         'Running'
Test-Val 'ドメイン参加'               (Get-Val $dbOut 'PART_OF_DOMAIN')  'True'
Write-Host "         ドメイン名: $(Get-Val $dbOut 'DOMAIN')" -ForegroundColor Gray
Test-Val 'データドライブ F:\SQLData'  (Get-Val $dbOut 'DATA_DRIVE')      'True'

# ============================================================
# 6. APP01: IIS + ドメイン参加
# ============================================================
Write-Host "`n=== 6. APP01: IIS + ドメイン参加 ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

$webScript = @'
$cs = Get-WmiObject Win32_ComputerSystem
Write-Output ('PART_OF_DOMAIN=' + $cs.PartOfDomain)
Write-Output ('DOMAIN=' + $cs.Domain)
Write-Output ('IIS=' + (Get-WindowsFeature Web-Server).InstallState)
Write-Output ('ASPNET45=' + (Get-WindowsFeature Web-Asp-Net45).InstallState)
'@

$webOut = Invoke-VmCommand 'vm-onprem-web' $webScript

Test-Val 'IIS インストール'  (Get-Val $webOut 'IIS')            'Installed'
Test-Val 'ASP.NET 4.5'       (Get-Val $webOut 'ASPNET45')        'Installed'
Test-Val 'ドメイン参加'       (Get-Val $webOut 'PART_OF_DOMAIN')  'True'
Write-Host "         ドメイン名: $(Get-Val $webOut 'DOMAIN')" -ForegroundColor Gray

# ============================================================
# 7. 内部疎通 (APP01 から)
# ============================================================
Write-Host "`n=== 7. 内部疎通 (APP01 から) ===" -ForegroundColor Cyan
Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

$dcFqdn = if ($adDomain) { "DC01.$adDomain" } else { 'DC01' }
$connScript = @"
`$d = Test-NetConnection -ComputerName 10.0.1.4 -Port 3389 -WarningAction SilentlyContinue
Write-Output ('DC_RDP=' + `$d.TcpTestSucceeded)
`$b = Test-NetConnection -ComputerName 10.0.1.5 -Port 3389 -WarningAction SilentlyContinue
Write-Output ('DB_RDP=' + `$b.TcpTestSucceeded)
`$r = Resolve-DnsName $dcFqdn -ErrorAction SilentlyContinue
Write-Output ('DNS_RESOLVE=' + `$r[0].IPAddress)
"@

$connOut = Invoke-VmCommand 'vm-onprem-web' $connScript

Test-Val     'APP01 → DC01:3389'    (Get-Val $connOut 'DC_RDP')      'True'
Test-Val     'APP01 → DB01:3389'    (Get-Val $connOut 'DB_RDP')      'True'
Test-NotEmpty "DNS $dcFqdn"         (Get-Val $connOut 'DNS_RESOLVE')

# ============================================================
# 8. Parts Unlimited (Setup-SqlServer / Setup-PartsUnlimited 実行後)
# ============================================================
if (-not $SkipPartsUnlimited) {
    Write-Host "`n=== 8. Parts Unlimited ===" -ForegroundColor Cyan
    Write-Host "  リモートコマンド実行中..." -ForegroundColor Gray

    $puOut = Invoke-VmCommand 'vm-onprem-web' @'
$s = Test-NetConnection -ComputerName 10.0.1.5 -Port 1433 -WarningAction SilentlyContinue
Write-Output ('SQL_PORT=' + $s.TcpTestSucceeded)
try { $c = (Invoke-WebRequest -Uri http://localhost -UseBasicParsing -TimeoutSec 5).StatusCode } catch { $c = 'Error' }
Write-Output ('HTTP=' + $c)
try { $b = (Invoke-WebRequest -Uri http://localhost -UseBasicParsing -TimeoutSec 5).Content; if ($b -match 'Parts Unlimited') { Write-Output 'PARTS=OK' } else { Write-Output 'PARTS=NotFound' } } catch { Write-Output 'PARTS=Error' }
'@

    Test-Val 'APP01 → DB01:1433' (Get-Val $puOut 'SQL_PORT') 'True'
    Test-Val 'HTTP 応答'          (Get-Val $puOut 'HTTP')     '200'
    Test-Val 'Parts Unlimited'   (Get-Val $puOut 'PARTS')    'OK'
} else {
    Write-Host "`n=== 8. Parts Unlimited [SKIP] ===" -ForegroundColor DarkGray
    Write-Host '  [SKIP] APP01 → DB01:1433 — Setup-SqlServer 未実行' -ForegroundColor DarkGray
    Write-Host '  [SKIP] HTTP / Parts Unlimited — Setup-PartsUnlimited 未実行' -ForegroundColor DarkGray
}

# ============================================================
# サマリ
# ============================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== 結果: {0} / {1} 通過 ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  上記の [FAIL] を確認してください。" -ForegroundColor Yellow
}
