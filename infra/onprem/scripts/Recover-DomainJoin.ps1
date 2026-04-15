<#
.SYNOPSIS
    ドメイン参加エラーのリカバリ — 失敗した DomainJoin 拡張を削除して再実行
.DESCRIPTION
    DC01 の AD DS 昇格 + 再起動が完了する前に DB01/APP01 の DomainJoin 拡張が
    実行されると 0x54b (DC に到達できない) で失敗する。
    このスクリプトは DC01 の起動完了を確認後、失敗した拡張を削除して再実行する。
.EXAMPLE
    .\Recover-DomainJoin.ps1 -AdminPassword 'P@ssw0rd1234!'
.EXAMPLE
    .\Recover-DomainJoin.ps1 -AdminPassword 'P@ssw0rd1234!' -ResourceGroup rg-onprem
#>

param(
    [Parameter(Mandatory)]
    [string]$AdminPassword,

    [string]$ResourceGroup = 'rg-onprem',
    [string]$DomainName = 'lab.local',
    [string]$AdminUsername = 'labadmin',
    [string[]]$TargetVMs = @('vm-onprem-sql', 'vm-onprem-web')
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# [1/3] DC01 の起動完了を確認
# =============================================================================
Write-Host '=== ドメイン参加リカバリ ===' -ForegroundColor Cyan
Write-Host ''
Write-Host '[1/3] DC01 (vm-onprem-ad) の起動状態を確認中...' -ForegroundColor Yellow

$dcStatus = az vm get-instance-view -g $ResourceGroup -n vm-onprem-ad `
    --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null

if ($dcStatus -ne 'VM running') {
    Write-Host "  DC01 の状態: $dcStatus" -ForegroundColor Red
    Write-Host '  DC01 が起動完了するまで待機してください。' -ForegroundColor Red
    exit 1
}
Write-Host "  DC01 の状態: $dcStatus" -ForegroundColor Green

# AD DS が応答するか確認 (DNS ポート 53 への到達性)
Write-Host '  AD DS の応答を確認中...' -ForegroundColor Gray
$adCheck = az vm run-command invoke -g $ResourceGroup -n vm-onprem-ad `
    --command-id RunPowerShellScript `
    --scripts "Get-ADDomain -ErrorAction Stop | Select-Object -ExpandProperty DNSRoot" `
    --query "value[?code=='ComponentStatus/StdOut/succeeded'].message" -o tsv 2>$null

if ($adCheck -match $DomainName) {
    Write-Host "  AD DS 応答確認: $($adCheck.Trim())" -ForegroundColor Green
} else {
    Write-Host '  AD DS がまだ応答していません。DC01 の再起動完了を待ってから再実行してください。' -ForegroundColor Red
    Write-Host "  出力: $adCheck" -ForegroundColor DarkGray
    exit 1
}

# =============================================================================
# [2/3] 失敗した DomainJoin 拡張を削除
# =============================================================================
Write-Host ''
Write-Host '[2/3] 失敗した DomainJoin 拡張を削除中...' -ForegroundColor Yellow

foreach ($vm in $TargetVMs) {
    $extStatus = az vm extension show -g $ResourceGroup --vm-name $vm -n DomainJoin `
        --query "provisioningState" -o tsv 2>$null

    if ($extStatus) {
        Write-Host "  $vm : DomainJoin ($extStatus) を削除中..." -ForegroundColor Gray
        az vm extension delete -g $ResourceGroup --vm-name $vm -n DomainJoin -o none
        Write-Host "  $vm : 削除完了" -ForegroundColor Green
    } else {
        Write-Host "  $vm : DomainJoin 拡張なし (スキップ)" -ForegroundColor DarkGray
    }
}

# =============================================================================
# [3/3] DomainJoin 拡張を再実行
# =============================================================================
Write-Host ''
Write-Host '[3/3] DomainJoin 拡張を再実行中...' -ForegroundColor Yellow

$settings = @{
    Name    = $DomainName
    User    = "${DomainName}\${AdminUsername}"
    Restart = 'true'
    Options = '3'
} | ConvertTo-Json -Compress

$protectedSettings = @{
    Password = $AdminPassword
} | ConvertTo-Json -Compress

foreach ($vm in $TargetVMs) {
    Write-Host "  $vm : ドメイン参加を実行中..." -ForegroundColor Gray

    $azArgs = @(
        'vm', 'extension', 'set'
        '--resource-group', $ResourceGroup
        '--vm-name', $vm
        '--name', 'JsonADDomainExtension'
        '--publisher', 'Microsoft.Compute'
        '--version', '1.3'
        '--extension-instance-name', 'DomainJoin'
        '--settings', $settings
        '--protected-settings', $protectedSettings
        '-o', 'none'
    )
    az @azArgs 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  $vm : ドメイン参加成功" -ForegroundColor Green
    } else {
        Write-Host "  $vm : ドメイン参加失敗 (exit code: $LASTEXITCODE)" -ForegroundColor Red
    }
}

# =============================================================================
# 結果確認
# =============================================================================
Write-Host ''
Write-Host '=== 結果確認 ===' -ForegroundColor Cyan

foreach ($vm in $TargetVMs) {
    $state = az vm extension show -g $ResourceGroup --vm-name $vm -n JsonADDomainExtension `
        --query "provisioningState" -o tsv 2>$null
    $color = if ($state -eq 'Succeeded') { 'Green' } else { 'Red' }
    Write-Host "  $vm : $state" -ForegroundColor $color
}
