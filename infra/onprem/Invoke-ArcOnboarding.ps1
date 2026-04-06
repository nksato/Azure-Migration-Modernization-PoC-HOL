<#
.SYNOPSIS
    ラボ環境の Azure VM を Azure Arc 対応サーバーとして登録するオーケストレーター
.DESCRIPTION
    az vm run-command invoke + @file 構文で VM 内スクリプト (Setup-ArcAgent.ps1) を
    送信・実行します。エスケープ問題を回避し、VM 内スクリプトの単体テストも容易です。

    実行手順:
    0. 事前チェック (Azure CLI ログイン、VM 一覧)
    1. サービス プリンシパルの作成
    2. 各 VM の事前準備 (MSFT_ARC_TEST 環境変数、拡張機能削除)
    3. Setup-ArcAgent.ps1 を @file で送信・実行
    4. 接続結果の確認
    5. サービス プリンシパルのクリーンアップ (自動作成時のみ)

    参考: https://learn.microsoft.com/ja-jp/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine
.PARAMETER ResourceGroupName
    VM が存在するリソースグループ名
.PARAMETER ArcResourceGroupName
    Arc リソースを登録するリソースグループ名 (省略時は ResourceGroupName と同じ)
.PARAMETER Location
    Arc リソースのリージョン (既定: japaneast)
.PARAMETER TenantId
    Azure AD テナント ID (省略時は現在のコンテキストから取得)
.PARAMETER SubscriptionId
    サブスクリプション ID (省略時は現在のコンテキストから取得)
.PARAMETER ServicePrincipalId
    既存のサービス プリンシパル アプリケーション ID (省略時は自動作成)
.PARAMETER VmNames
    Arc 対応にする VM 名の配列 (既定: vm-onprem-ad, vm-onprem-sql, vm-onprem-web)
.EXAMPLE
    .\Invoke-ArcOnboarding.ps1 -ResourceGroupName "rg-onprem"
.EXAMPLE
    .\Invoke-ArcOnboarding.ps1 -ResourceGroupName "rg-onprem" -VmNames @("vm-onprem-web")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$ArcResourceGroupName = '',
    [string]$Location = 'japaneast',
    [string]$TenantId = '',
    [string]$SubscriptionId = '',
    [string]$ServicePrincipalId = '',

    [string[]]$VmNames = @('vm-onprem-ad', 'vm-onprem-sql', 'vm-onprem-web')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$spName = 'arc-onboarding-lab'
$spAutoCreated = $false

# ============================================================
# ヘルパー関数
# ============================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Ensure-VmRunning {
    param(
        [string]$ResourceGroup,
        [string]$VmName
    )

    $powerState = az vm get-instance-view -g $ResourceGroup -n $VmName `
        --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null

    if ($powerState -ne 'VM running') {
        Write-Host "  [$VmName] VM が停止しています ($powerState)。起動します..." -ForegroundColor Yellow
        az vm start -g $ResourceGroup -n $VmName -o none
        if ($LASTEXITCODE -ne 0) {
            throw "[$VmName] VM の起動に失敗しました"
        }
        Write-Host "  [$VmName] VM が起動しました" -ForegroundColor Green
    }
}

# VM 内スクリプトのパスを解決
$setupScriptPath = Join-Path (Join-Path $PSScriptRoot 'scripts') 'Setup-ArcAgent-en.ps1'
if (-not (Test-Path $setupScriptPath)) {
    throw "VM 内スクリプトが見つかりません: $setupScriptPath"
}

# ============================================================
# 0. 事前チェック
# ============================================================

Write-Step "0. 事前チェック"

$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Azure CLI にログインしてください: az login"
}
Write-Host "  サブスクリプション: $($account.name) ($($account.id))" -ForegroundColor Green

if (-not $TenantId) { $TenantId = $account.tenantId }
if (-not $SubscriptionId) { $SubscriptionId = $account.id }
if (-not $ArcResourceGroupName) { $ArcResourceGroupName = $ResourceGroupName }

Write-Host "  テナント ID       : $TenantId" -ForegroundColor White
Write-Host "  サブスクリプション: $SubscriptionId" -ForegroundColor White
Write-Host "  Arc リソース RG   : $ArcResourceGroupName" -ForegroundColor White
Write-Host "  対象 VM           : $($VmNames -join ', ')" -ForegroundColor White
Write-Host "  VM 内スクリプト   : $setupScriptPath" -ForegroundColor White

# ============================================================
# 1. サービス プリンシパルの準備
# ============================================================

Write-Step "1. サービス プリンシパルの準備"

if (-not $ServicePrincipalId) {
    Write-Host "  Arc オンボーディング用サービス プリンシパルを作成します..." -ForegroundColor Yellow

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $spRaw = az ad sp create-for-rbac `
        --name $spName `
        --role "Azure Connected Machine Onboarding" `
        --scopes "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName" `
        -o json 2>&1
    $ErrorActionPreference = $prevEAP

    if ($LASTEXITCODE -ne 0) {
        throw "サービス プリンシパルの作成に失敗しました: $spRaw"
    }

    $spJson = ($spRaw | Where-Object { $_ -is [string] }) -join "`n"
    $sp = $spJson | ConvertFrom-Json
    $ServicePrincipalId = $sp.appId
    $spSecret = $sp.password
    $spAutoCreated = $true

    Write-Host "  サービス プリンシパル作成完了" -ForegroundColor Green
    Write-Host "    名前   : $spName" -ForegroundColor White
    Write-Host "    App ID : $ServicePrincipalId" -ForegroundColor White
}
else {
    Write-Host "  既存のサービス プリンシパルを使用します: $ServicePrincipalId" -ForegroundColor Green
    $spSecretSecure = Read-Host -Prompt "サービス プリンシパルのシークレットを入力してください" -AsSecureString
    $spSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($spSecretSecure)
    )
}

# ============================================================
# 2. 各 VM の事前準備
# ============================================================

foreach ($vmName in $VmNames) {
    Write-Step "2. [$vmName] 事前準備"

    Ensure-VmRunning -ResourceGroup $ResourceGroupName -VmName $vmName

    # --- 2a. 環境変数 MSFT_ARC_TEST を設定 ---
    Write-Host "  [$vmName] MSFT_ARC_TEST 環境変数を設定中..." -ForegroundColor Yellow
    az vm run-command invoke `
        --resource-group $ResourceGroupName `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts "[System.Environment]::SetEnvironmentVariable('MSFT_ARC_TEST','true',[System.EnvironmentVariableTarget]::Machine); Write-Output 'MSFT_ARC_TEST=true set'" `
        --query "value[?code=='ComponentStatus/StdOut/succeeded'].message" -o tsv
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [$vmName] MSFT_ARC_TEST の設定に失敗しました。" -ForegroundColor Red
    }

    # --- 2b. VM 拡張機能を削除 ---
    Write-Host "  [$vmName] VM 拡張機能を確認中..." -ForegroundColor Yellow
    $extensions = az vm extension list `
        --resource-group $ResourceGroupName `
        --vm-name $vmName `
        --query "[].name" -o tsv 2>$null

    if ($extensions) {
        foreach ($ext in $extensions -split "`n") {
            $ext = $ext.Trim()
            if ($ext) {
                Write-Host "  [$vmName] 拡張機能 '$ext' を削除中..." -ForegroundColor Yellow
                az vm extension delete `
                    --resource-group $ResourceGroupName `
                    --vm-name $vmName `
                    --name $ext `
                    -o none 2>$null
                Write-Host "  [$vmName] 拡張機能 '$ext' を削除しました。" -ForegroundColor Green
            }
        }
    }
    else {
        Write-Host "  [$vmName] 削除対象の拡張機能はありません。" -ForegroundColor Green
    }

    # 拡張機能削除後に VM が停止する場合があるため再確認
    Ensure-VmRunning -ResourceGroup $ResourceGroupName -VmName $vmName
}

# ============================================================
# 3. Setup-ArcAgent.ps1 を @file で送信・実行
# ============================================================

foreach ($vmName in $VmNames) {
    Write-Step "3. [$vmName] Arc Agent セットアップ"

    Ensure-VmRunning -ResourceGroup $ResourceGroupName -VmName $vmName

    $arcResourceName = "$vmName-Arc"

    Write-Host "  [$vmName] Setup-ArcAgent.ps1 を実行中..." -ForegroundColor Yellow
    Write-Host "  (IMDS ブロック → Agent インストール → Arc 接続 → ゲスト エージェント無効化[遅延])" -ForegroundColor Gray

    $resultJson = az vm run-command invoke `
        --resource-group $ResourceGroupName `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts "@$setupScriptPath" `
        --parameters "ServicePrincipalId=$ServicePrincipalId" `
                     "ServicePrincipalSecret=$spSecret" `
                     "TenantId=$TenantId" `
                     "SubscriptionId=$SubscriptionId" `
                     "ResourceGroupName=$ArcResourceGroupName" `
                     "Location=$Location" `
                     "ResourceName=$arcResourceName" `
        -o json

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [$vmName] Arc セットアップに失敗しました。" -ForegroundColor Red
    }
    else {
        Write-Host "  [$vmName] 結果:" -ForegroundColor Green
    }

    # run-command の stdout/stderr を整形して表示
    try {
        $parsed = $resultJson | ConvertFrom-Json
        foreach ($entry in $parsed.value) {
            $code = $entry.code
            $msg  = $entry.message
            if ($msg) {
                $color = if ($code -eq 'ComponentStatus/StdErr/succeeded') { 'Yellow' } else { 'Gray' }
                $msg -split "`n" | ForEach-Object {
                    Write-Host "    $_" -ForegroundColor $color
                }
            }
        }
    }
    catch {
        # JSON パース失敗時はそのまま出力
        Write-Host $resultJson -ForegroundColor Gray
    }
}

# ============================================================
# 4. 接続結果の確認
# ============================================================

Write-Step "4. Azure Arc 接続状況の確認"

$arcResources = az resource list `
    --resource-group $ArcResourceGroupName `
    --resource-type "Microsoft.HybridCompute/machines" `
    --query "[].{name:name, status:properties.status, location:location}" `
    -o table 2>$null

if ($arcResources) {
    foreach ($line in $arcResources) {
        Write-Host "  $line" -ForegroundColor Green
    }
}
else {
    Write-Host "  Arc リソースが見つかりません。接続が完了するまで数分かかる場合があります。" -ForegroundColor Yellow
    Write-Host "  Azure Portal で確認してください: Azure Arc > サーバー" -ForegroundColor Yellow
}

# シークレットをメモリからクリア
$spSecret = $null
[System.GC]::Collect()

# ============================================================
# 5. サービス プリンシパルのクリーンアップ
# ============================================================

if ($spAutoCreated) {
    Write-Step "5. サービス プリンシパルのクリーンアップ"

    Write-Host "  ロール割り当てを削除中..." -ForegroundColor Yellow
    az role assignment delete `
        --assignee $ServicePrincipalId `
        --role "Azure Connected Machine Onboarding" `
        --scope "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName" `
        -o none 2>$null
    Write-Host "  ロール割り当てを削除しました" -ForegroundColor Green

    Write-Host "  アプリ登録 (サービス プリンシパル) を削除中..." -ForegroundColor Yellow
    az ad app delete --id $ServicePrincipalId -o none 2>$null
    Write-Host "  アプリ登録 '$spName' (App ID: $ServicePrincipalId) を削除しました" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Arc 対応の処理が完了しました" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  確認方法:" -ForegroundColor White
Write-Host "    - Azure Portal → Azure Arc → サーバー" -ForegroundColor Gray
Write-Host "    - az connectedmachine list -g $ArcResourceGroupName ``" -ForegroundColor Gray
Write-Host "        --query ""[].{Name:name, Status:status, OS:osName, Agent:agentVersion}"" -o table" -ForegroundColor Gray
Write-Host ""

# connectedmachine で詳細表示 (status 含む)
$cmList = az connectedmachine list -g $ArcResourceGroupName `
    --query "[].{Name:name, Status:status, OS:osName, Agent:agentVersion, Location:location}" `
    -o table 2>$null
if ($cmList) {
    foreach ($line in $cmList) {
        Write-Host "  $line" -ForegroundColor White
    }
    Write-Host ""
}
