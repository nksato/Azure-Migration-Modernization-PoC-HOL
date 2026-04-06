<#
.SYNOPSIS
    Azure Arc オンボーディングの状態をリモートから検証する
.DESCRIPTION
    Enable-ArcOnVMs.ps1 による Arc 登録が正しく完了しているかを確認する。
    チェック項目:
      1. Azure 側 — Arc リソース (Microsoft.HybridCompute/machines) の存在とステータス
      2. VM 側  — 環境変数 MSFT_ARC_TEST / ゲストエージェント停止 / IMDS ブロック
      3. VM 側  — Connected Machine Agent のインストールと接続状態
.EXAMPLE
    .\Verify-ArcOnboarding.ps1
    .\Verify-ArcOnboarding.ps1 -ArcResourceGroupName "rg-arc"
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-onprem',
    [string]$ArcResourceGroupName = '',
    [string[]]$VmNames = @('vm-onprem-ad', 'vm-onprem-sql', 'vm-onprem-web')
)

$ErrorActionPreference = 'Continue'
if (-not $ArcResourceGroupName) { $ArcResourceGroupName = $ResourceGroupName }
$total = 0; $passed = 0

# --- ヘルパー ---

function Invoke-VmCommand ([string]$VmName, [string]$Script) {
    $oneLiner = ($Script -split "`r?`n" | Where-Object { $_.Trim() }) -join '; '
    $raw = az vm run-command invoke `
        --resource-group $ResourceGroupName --name $VmName `
        --command-id RunPowerShellScript --scripts $oneLiner -o json 2>&1
    $json = ($raw | Where-Object { $_ -notmatch '^WARNING' }) -join ''
    $r = $json | ConvertFrom-Json
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

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Azure Arc オンボーディング検証" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 1. Azure 側: Arc リソースの確認
# ============================================================

Write-Host "--- 1. Azure Arc リソースの確認 ($ArcResourceGroupName) ---" -ForegroundColor Yellow

foreach ($vmName in $VmNames) {
    # Enable-ArcOnVMs.ps1 は "$vmName-Arc" でリソースを登録する
    $arcName = "$vmName-Arc"
    $arcJson = az connectedmachine show `
        --resource-group $ArcResourceGroupName `
        --name $arcName `
        -o json 2>$null

    if ($arcJson) {
        $arc = $arcJson | ConvertFrom-Json
        Test-Val "$arcName リソース存在" 'True' 'True'
        Test-Val "$arcName 接続状態" $arc.status 'Connected'
        Test-Match "$arcName エージェントバージョン" $arc.agentVersion '^\d+\.\d+'
        Write-Host "         OS: $($arc.osName) $($arc.osVersion)" -ForegroundColor Gray
    }
    else {
        Test-Val "$arcName リソース存在" 'False' 'True'
    }
}

# ============================================================
# 2. VM 側: Arc 対応準備の確認
# ============================================================

foreach ($vmName in $VmNames) {
    Write-Host ""
    Write-Host "--- 2. [$vmName] Arc 対応準備の確認 ---" -ForegroundColor Yellow

    $prepOut = Invoke-VmCommand -VmName $vmName -Script @'
Write-Output ('MSFT_ARC_TEST=' + [System.Environment]::GetEnvironmentVariable('MSFT_ARC_TEST', 'Machine'))
$svc = Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue
if ($svc) {
    Write-Output ('GUEST_AGENT_STATUS=' + $svc.Status)
    Write-Output ('GUEST_AGENT_STARTUP=' + $svc.StartType)
} else {
    Write-Output 'GUEST_AGENT_STATUS=NotFound'
    Write-Output 'GUEST_AGENT_STARTUP=NotFound'
}
$imds1 = Get-NetFirewallRule -Name 'BlockAzureIMDS' -ErrorAction SilentlyContinue
Write-Output ('IMDS_BLOCK=' + $(if ($imds1) { $imds1.Enabled } else { 'NotFound' }))
$imds2 = Get-NetFirewallRule -Name 'BlockAzureIMDS_AzureLocal' -ErrorAction SilentlyContinue
Write-Output ('IMDS_LOCAL_BLOCK=' + $(if ($imds2) { $imds2.Enabled } else { 'NotFound' }))
'@

    if (-not $prepOut) {
        Write-Host "  [FAIL] [$vmName] VM コマンド実行失敗" -ForegroundColor Red
        $script:total += 4; continue
    }

    # 環境変数 MSFT_ARC_TEST
    Test-Val "[$vmName] MSFT_ARC_TEST" (Get-Val $prepOut 'MSFT_ARC_TEST') 'true'

    # ゲストエージェント停止
    $guestStatus = Get-Val $prepOut 'GUEST_AGENT_STATUS'
    $guestStartup = Get-Val $prepOut 'GUEST_AGENT_STARTUP'
    Test-Match "[$vmName] ゲストエージェント状態" $guestStatus 'Stopped|NotFound'
    Test-Val "[$vmName] ゲストエージェント起動種別" $guestStartup 'Disabled'

    # IMDS ブロック
    Test-Val "[$vmName] IMDS ブロック (169.254.169.254)" (Get-Val $prepOut 'IMDS_BLOCK') 'True'
    Test-Val "[$vmName] IMDS ブロック (169.254.169.253)" (Get-Val $prepOut 'IMDS_LOCAL_BLOCK') 'True'

    # --- 3. Connected Machine Agent の確認 ---
    Write-Host ""
    Write-Host "--- 3. [$vmName] Connected Machine Agent の確認 ---" -ForegroundColor Yellow

    $agentOut = Invoke-VmCommand -VmName $vmName -Script @'
$agentPath = "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe"
Write-Output ('AGENT_INSTALLED=' + (Test-Path $agentPath))
if (Test-Path $agentPath) {
    $showRaw = & $agentPath show 2>&1
    $status = ($showRaw | Select-String -Pattern '^Agent Status' | Select-Object -First 1) -replace '.*:\s*', ''
    $name   = ($showRaw | Select-String -Pattern '^Resource Name' | Select-Object -First 1) -replace '.*:\s*', ''
    $rg     = ($showRaw | Select-String -Pattern '^Resource Group' | Select-Object -First 1) -replace '.*:\s*', ''
    Write-Output ('AGENT_STATUS=' + $status.Trim())
    Write-Output ('AGENT_RESOURCE_NAME=' + $name.Trim())
    Write-Output ('AGENT_RESOURCE_GROUP=' + $rg.Trim())
}
'@

    if (-not $agentOut) {
        Write-Host "  [FAIL] [$vmName] VM コマンド実行失敗" -ForegroundColor Red
        $script:total += 3; continue
    }

    Test-Val "[$vmName] Agent インストール済み" (Get-Val $agentOut 'AGENT_INSTALLED') 'True'
    Test-Val "[$vmName] Agent 状態" (Get-Val $agentOut 'AGENT_STATUS') 'Connected'
    Test-Val "[$vmName] Agent リソース名" (Get-Val $agentOut 'AGENT_RESOURCE_NAME') "$vmName-Arc"
    Test-Val "[$vmName] Agent リソースグループ" (Get-Val $agentOut 'AGENT_RESOURCE_GROUP') $ArcResourceGroupName
}

# ============================================================
# サマリー
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
$color = if ($passed -eq $total) { 'Green' } else { 'Red' }
Write-Host "  結果: $passed / $total PASS" -ForegroundColor $color
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

exit $(if ($passed -eq $total) { 0 } else { 1 })
