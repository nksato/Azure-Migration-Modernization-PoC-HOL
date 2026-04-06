
<#
.SYNOPSIS
    Azure Arc オンボーディングの状態をリモートから検証する
.DESCRIPTION
    Enable-ArcOnVMs.ps1 / Invoke-ArcOnboarding.ps1 による Arc 登録が正しく完了しているかを確認する。
    セクション 2, 3 は az connectedmachine run-command (Arc エージェント経由) で
    VM 内コマンドを実行するため、ゲストエージェントが停止していても動作する。
    チェック項目:
      1. Azure 側 — Arc リソース (Microsoft.HybridCompute/machines) の存在とステータス
      2/3. VM 側 — 環境変数・ゲストエージェント・IMDS + Agent 状態 (1 回のリモート実行で取得)
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

# --- connectedmachine 拡張の確認 (run-command には 2.x 以上が必要) ---
$extVer = az extension show --name connectedmachine --query version -o tsv 2>$null
if (-not $extVer -or $extVer -lt '2') {
    Write-Host "  connectedmachine 拡張をアップデートしています..." -ForegroundColor Yellow
    az extension update --name connectedmachine --allow-preview true -o none 2>$null
    if (-not $?) {
        az extension add --name connectedmachine --allow-preview true -o none 2>$null
    }
}

# --- ヘルパー ---

function Invoke-ArcCommand ([string]$VmName, [string]$Script) {
    $arcName = "$VmName-Arc"
    # 固定名を使い回すことで、前回の run-command を上書き (delete 不要)
    $cmdName = 'verify-arc'

    # 複数行スクリプトを 1 行に結合 (az CLI --script は改行で途切れる)
    $oneLine = ($Script -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join '; '

    $raw = az connectedmachine run-command create `
        --resource-group $ArcResourceGroupName `
        --machine-name $arcName `
        --run-command-name $cmdName `
        --script "$oneLine" `
        -o json 2>&1

    $json = ($raw | Where-Object { $_ -is [string] }) -join "`n"
    try {
        $r = $json | ConvertFrom-Json
    }
    catch {
        Write-Host "         JSON parse error: $json" -ForegroundColor DarkYellow
        return $null
    }

    $stderr = $r.instanceView.error
    if ($stderr) { Write-Host "         stderr: $stderr" -ForegroundColor DarkYellow }

    $r.instanceView.output
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
    Write-Host "--- 2/3. [$vmName] VM 設定 + Agent の確認 ---" -ForegroundColor Yellow
    Write-Host "  リモートコマンド実行中 (1 回で全チェック)..." -ForegroundColor Gray

    # セクション 2 (環境/サービス/FW) + セクション 3 (azcmagent show) を 1 回で実行
    $allOut = Invoke-ArcCommand -VmName $vmName -Script @'
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
Write-Output '---AGENT---'
if (Test-Path 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe') { & 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe' show } else { Write-Output 'NOT_INSTALLED' }
'@

    if (-not $allOut) {
        Write-Host "  [FAIL] [$vmName] VM コマンド実行失敗" -ForegroundColor Red
        $script:total += 9; continue
    }

    # マーカーで分割
    $parts = ($allOut -split '---AGENT---', 2)
    $prepOut  = $parts[0].Trim()
    $agentOut = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

    # --- セクション 2: Arc 対応準備 ---
    Test-Val "[$vmName] MSFT_ARC_TEST" (Get-Val $prepOut 'MSFT_ARC_TEST') 'true'

    $guestStatus = Get-Val $prepOut 'GUEST_AGENT_STATUS'
    $guestStartup = Get-Val $prepOut 'GUEST_AGENT_STARTUP'
    Test-Match "[$vmName] ゲストエージェント状態" $guestStatus 'Stopped|NotFound'
    Test-Val "[$vmName] ゲストエージェント起動種別" $guestStartup 'Disabled'

    Test-Val "[$vmName] IMDS ブロック (169.254.169.254)" (Get-Val $prepOut 'IMDS_BLOCK') 'True'
    Test-Val "[$vmName] IMDS ブロック (169.254.169.253)" (Get-Val $prepOut 'IMDS_LOCAL_BLOCK') 'True'

    # --- セクション 3: Connected Machine Agent ---
    $installed = $agentOut -and ($agentOut -notmatch 'NOT_INSTALLED')
    Test-Val "[$vmName] Agent インストール済み" "$installed" 'True'

    if ($installed) {
        $agentStatus = ($agentOut -split "`n" | Where-Object { $_ -match '^\s*Agent Status' } | Select-Object -First 1) -replace '.*:\s*', '' | ForEach-Object { $_.Trim() }
        $agentName   = ($agentOut -split "`n" | Where-Object { $_ -match '^\s*Resource Name' } | Select-Object -First 1) -replace '.*:\s*', '' | ForEach-Object { $_.Trim() }
        $agentRg     = ($agentOut -split "`n" | Where-Object { $_ -match '^\s*Resource Group' } | Select-Object -First 1) -replace '.*:\s*', '' | ForEach-Object { $_.Trim() }

        Test-Val "[$vmName] Agent 状態" $agentStatus 'Connected'
        Test-Val "[$vmName] Agent リソース名" $agentName "$vmName-Arc"
        Test-Val "[$vmName] Agent リソースグループ" $agentRg $ArcResourceGroupName
    }
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
