<#
.SYNOPSIS
    ラボ環境の Azure VM を Azure Arc 対応サーバーとして登録するスクリプト
.DESCRIPTION
    Azure VM 上で Azure Arc 対応サーバーを評価するため、以下の手順を自動実行します。
    1. 環境変数 MSFT_ARC_TEST を設定 (Azure VM 上での Arc インストールを許可)
    2. VM 拡張機能を削除
    3. Azure VM ゲスト エージェントを無効化
    4. IMDS エンドポイントへのアクセスをブロック (ファイアウォール ルール)
    5. Azure Connected Machine Agent をインストール
    6. azcmagent connect で Azure Arc に接続

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
    Azure Connected Machine Onboarding ロールを持つサービス プリンシパルのアプリケーション ID
.PARAMETER VmNames
    Arc 対応にする VM 名の配列 (既定: vm-onprem-ad, vm-onprem-sql, vm-onprem-web)
.EXAMPLE
    .\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onprem"
.EXAMPLE
    .\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onprem" -VmNames @("vm-onprem-web")
.EXAMPLE
    .\Enable-ArcOnVMs.ps1 -ResourceGroupName "rg-onprem" -ArcResourceGroupName "rg-arc" -ServicePrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
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

function Invoke-VmRunCommand {
    <#
    .SYNOPSIS
        VM 上でスクリプトを実行し、結果を返す
    #>
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$Script,
        [string]$Description = ''
    )

    if ($Description) {
        Write-Host "  [$VmName] $Description" -ForegroundColor Yellow
    }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $result = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $VmName `
        --command-id RunPowerShellScript `
        --scripts $Script `
        -o json 2>&1
    $ErrorActionPreference = $prevEAP

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [$VmName] コマンド実行に失敗しました: $result" -ForegroundColor Red
        return $null
    }

    # stderr 由来の WARNING 行 (ErrorRecord) を文字列化してから除外し JSON のみパース
    $jsonText = ($result | ForEach-Object { $_.ToString() } | Where-Object { $_ -notmatch '^WARNING' }) -join "`n"
    $parsed = $jsonText | ConvertFrom-Json
    $stdout = $parsed.value | Where-Object { $_.code -like '*StdOut*' } | Select-Object -ExpandProperty message
    $stderr = $parsed.value | Where-Object { $_.code -like '*StdErr*' } | Select-Object -ExpandProperty message

    if ($stderr) {
        Write-Host "  [$VmName] StdErr: $stderr" -ForegroundColor Yellow
    }
    if ($stdout) {
        Write-Host "  [$VmName] $stdout" -ForegroundColor Gray
    }

    return $stdout
}

function Ensure-VmRunning {
    <#
    .SYNOPSIS
        VM が起動中であることを確認し、停止していれば起動する
    #>
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

# ============================================================
# 0. 事前準備
# ============================================================

Write-Step "0. 事前チェック"

# Azure CLI ログイン確認
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Azure CLI にログインしてください: az login"
}
Write-Host "  サブスクリプション: $($account.name) ($($account.id))" -ForegroundColor Green

if (-not $TenantId) {
    $TenantId = $account.tenantId
}
if (-not $SubscriptionId) {
    $SubscriptionId = $account.id
}
if (-not $ArcResourceGroupName) {
    $ArcResourceGroupName = $ResourceGroupName
}

Write-Host "  テナント ID       : $TenantId" -ForegroundColor White
Write-Host "  サブスクリプション: $SubscriptionId" -ForegroundColor White
Write-Host "  Arc リソース RG   : $ArcResourceGroupName" -ForegroundColor White
Write-Host "  対象 VM           : $($VmNames -join ', ')" -ForegroundColor White

# ============================================================
# 1. サービス プリンシパルの準備
# ============================================================

Write-Step "1. サービス プリンシパルの準備"

if (-not $ServicePrincipalId) {
    Write-Host "  Arc オンボーディング用サービス プリンシパルを作成します..." -ForegroundColor Yellow

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $spRaw = az ad sp create-for-rbac `
        --name "arc-onboarding-lab" `
        --role "Azure Connected Machine Onboarding" `
        --scopes "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroupName" `
        -o json 2>&1
    $ErrorActionPreference = $prevEAP

    if ($LASTEXITCODE -ne 0) {
        throw "サービス プリンシパルの作成に失敗しました: $spRaw"
    }

    # stderr 由来の WARNING 行 (ErrorRecord) を文字列化してから除外し JSON のみパース
    $spJson = ($spRaw | ForEach-Object { $_.ToString() } | Where-Object { $_ -notmatch '^WARNING' }) -join "`n"
    $sp = $spJson | ConvertFrom-Json
    $ServicePrincipalId = $sp.appId
    $spSecret = $sp.password

    Write-Host "  サービス プリンシパル作成完了" -ForegroundColor Green
    Write-Host "    App ID: $ServicePrincipalId" -ForegroundColor White
}
else {
    Write-Host "  既存のサービス プリンシパルを使用します: $ServicePrincipalId" -ForegroundColor Green
    $spSecretSecure = Read-Host -Prompt "サービス プリンシパルのシークレットを入力してください" -AsSecureString
    $spSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($spSecretSecure)
    )
}

# ============================================================
# 2. 各 VM を Arc 対応に準備
# ============================================================

foreach ($vmName in $VmNames) {
    Write-Step "2. [$vmName] Arc 対応の準備"

    # --- VM 起動確認 ---
    Ensure-VmRunning -ResourceGroup $ResourceGroupName -VmName $vmName

    # --- 2a. 環境変数 MSFT_ARC_TEST を設定 ---
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "環境変数 MSFT_ARC_TEST を設定" `
        -Script '[System.Environment]::SetEnvironmentVariable(''MSFT_ARC_TEST'',''true'',[System.EnvironmentVariableTarget]::Machine); Write-Output ''MSFT_ARC_TEST=true set'''

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

    # --- 拡張機能削除後に VM が停止する場合があるため再確認 ---
    Ensure-VmRunning -ResourceGroup $ResourceGroupName -VmName $vmName

    # --- 2c. Azure VM ゲスト エージェントを無効化 ---
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "Azure VM ゲスト エージェントを無効化" `
        -Script 'Set-Service WindowsAzureGuestAgent -StartupType Disabled; Stop-Service WindowsAzureGuestAgent -Force; Write-Output ''WindowsAzureGuestAgent disabled'''

    # --- 2d. IMDS エンドポイントをブロック ---
    $imdsScript = @'
$r1 = Get-NetFirewallRule -Name 'BlockAzureIMDS' -ErrorAction SilentlyContinue
if (-not $r1) {
    New-NetFirewallRule -Name 'BlockAzureIMDS' -DisplayName 'Block access to Azure IMDS' -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254
    Write-Output 'BlockAzureIMDS created'
} else {
    Write-Output 'BlockAzureIMDS exists'
}
$r2 = Get-NetFirewallRule -Name 'BlockAzureIMDS_AzureLocal' -ErrorAction SilentlyContinue
if (-not $r2) {
    New-NetFirewallRule -Name 'BlockAzureIMDS_AzureLocal' -DisplayName 'Block access to Azure Local IMDS' -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.253
    Write-Output 'BlockAzureIMDS_AzureLocal created'
} else {
    Write-Output 'BlockAzureIMDS_AzureLocal exists'
}
'@
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "IMDS エンドポイントへのアクセスをブロック" `
        -Script $imdsScript
}

# ============================================================
# 3. Azure Connected Machine Agent のインストールと接続
# ============================================================

foreach ($vmName in $VmNames) {
    Write-Step "3. [$vmName] Azure Connected Machine Agent のインストールと接続"

    # --- VM 起動確認 ---
    Ensure-VmRunning -ResourceGroup $ResourceGroupName -VmName $vmName

    # エージェントのダウンロードとインストール
    $installScript = @'
$agentExe = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
if (Test-Path $agentExe) {
    Write-Output 'Agent already installed'
} else {
    Write-Output 'Downloading agent...'
    $ProgressPreference = 'SilentlyContinue'
    $msi = Join-Path $env:TEMP 'install_windows_azcmagent.msi'
    Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $msi -UseBasicParsing
    Write-Output 'Installing agent...'
    $log = Join-Path $env:TEMP 'installationlog.txt'
    $exitCode = (Start-Process -FilePath msiexec.exe -ArgumentList '/i',$msi,'/l*v',$log,'/qn' -Wait -Passthru).ExitCode
    if ($exitCode -ne 0) {
        throw ('Agent install failed (ExitCode: ' + $exitCode + '). Log: ' + $log)
    }
    Write-Output 'Agent installed successfully'
}
'@
    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "Azure Connected Machine Agent をダウンロード・インストール" `
        -Script $installScript

    # azcmagent connect で Arc に接続
    # サービス プリンシパルの資格情報を使用
    $connectScript = @"
`$env:MSFT_ARC_TEST = 'true'
& 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe' connect ``
    --service-principal-id '$ServicePrincipalId' ``
    --service-principal-secret '$spSecret' ``
    --tenant-id '$TenantId' ``
    --subscription-id '$SubscriptionId' ``
    --resource-group '$ArcResourceGroupName' ``
    --location '$Location' ``
    --resource-name '$vmName-Arc'
if (`$LASTEXITCODE -eq 0) {
    Write-Output 'Arc connection succeeded'
} else {
    Write-Output ('Arc connection failed (ExitCode: ' + `$LASTEXITCODE + ')')
}
"@

    Invoke-VmRunCommand `
        -ResourceGroup $ResourceGroupName `
        -VmName $vmName `
        -Description "Azure Arc に接続" `
        -Script $connectScript
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
    Write-Host $arcResources -ForegroundColor Green
}
else {
    Write-Host "  Arc リソースが見つかりません。接続が完了するまで数分かかる場合があります。" -ForegroundColor Yellow
    Write-Host "  Azure Portal で確認してください: Azure Arc > サーバー" -ForegroundColor Yellow
}

# シークレットをメモリからクリア
$spSecret = $null
[System.GC]::Collect()

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Arc 対応の処理が完了しました" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  確認方法:" -ForegroundColor White
Write-Host "    Azure Portal → Azure Arc → サーバー" -ForegroundColor White
Write-Host "    または: az connectedmachine list -g $ArcResourceGroupName -o table" -ForegroundColor White
Write-Host ""
