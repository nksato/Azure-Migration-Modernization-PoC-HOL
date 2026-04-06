# ============================================================
# Setup-ArcAgent.ps1
# VM 内で実行: Arc 対応に必要な準備と接続を行う
# - IMDS エンドポイントをブロック
# - Azure Connected Machine Agent をインストール
# - Azure VM ゲスト エージェントを無効化
# - azcmagent connect で Azure Arc に接続
# ============================================================
# Usage (via az vm run-command):
#   az vm run-command invoke `
#     --resource-group rg-onprem --name vm-onprem-web `
#     --command-id RunPowerShellScript `
#     --scripts @infra/onprem/scripts/Setup-ArcAgent.ps1 `
#     --parameters "ServicePrincipalId=<appId>" "ServicePrincipalSecret=<secret>" `
#                  "TenantId=<tenantId>" "SubscriptionId=<subId>" `
#                  "ResourceGroupName=<rg>" "Location=japaneast" "ResourceName=vm-onprem-web-Arc"
# ============================================================

param(
    [Parameter(Mandatory)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory)]
    [string]$ServicePrincipalSecret,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$Location = 'japaneast',
    [string]$ResourceName = ''
)

$ErrorActionPreference = 'Stop'

Write-Output '=== Arc Agent Setup Started ==='

# ----------------------------------------------------------
# 1. IMDS エンドポイントをブロック
# ----------------------------------------------------------
Write-Output '[1/4] Blocking IMDS endpoints...'

$r1 = Get-NetFirewallRule -Name 'BlockAzureIMDS' -ErrorAction SilentlyContinue
if (-not $r1) {
    New-NetFirewallRule -Name 'BlockAzureIMDS' -DisplayName 'Block access to Azure IMDS' `
        -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254 | Out-Null
    Write-Output '  BlockAzureIMDS created'
} else {
    Write-Output '  BlockAzureIMDS already exists'
}

$r2 = Get-NetFirewallRule -Name 'BlockAzureIMDS_AzureLocal' -ErrorAction SilentlyContinue
if (-not $r2) {
    New-NetFirewallRule -Name 'BlockAzureIMDS_AzureLocal' -DisplayName 'Block access to Azure Local IMDS' `
        -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.253 | Out-Null
    Write-Output '  BlockAzureIMDS_AzureLocal created'
} else {
    Write-Output '  BlockAzureIMDS_AzureLocal already exists'
}

# ----------------------------------------------------------
# 2. Azure Connected Machine Agent をインストール
# ----------------------------------------------------------
Write-Output '[2/4] Installing Azure Connected Machine Agent...'

$agentExe = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
if (Test-Path $agentExe) {
    Write-Output '  Agent already installed'
} else {
    Write-Output '  Downloading agent...'
    $ProgressPreference = 'SilentlyContinue'
    $msi = Join-Path $env:TEMP 'install_windows_azcmagent.msi'
    Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $msi -UseBasicParsing
    Write-Output '  Installing agent...'
    $log = Join-Path $env:TEMP 'installationlog.txt'
    $exitCode = (Start-Process -FilePath msiexec.exe -ArgumentList '/i', $msi, '/l*v', $log, '/qn' -Wait -Passthru).ExitCode
    if ($exitCode -ne 0) {
        throw "Agent install failed (ExitCode: $exitCode). Log: $log"
    }
    Write-Output '  Agent installed successfully'
}

# ----------------------------------------------------------
# 3. Azure VM ゲスト エージェントを無効化
# ----------------------------------------------------------
Write-Output '[3/4] Disabling Azure VM Guest Agent...'

Set-Service WindowsAzureGuestAgent -StartupType Disabled
Stop-Service WindowsAzureGuestAgent -Force
Write-Output '  WindowsAzureGuestAgent disabled'

# ----------------------------------------------------------
# 4. Azure Arc に接続
# ----------------------------------------------------------
Write-Output '[4/4] Connecting to Azure Arc...'

$env:MSFT_ARC_TEST = 'true'

$connectArgs = @(
    'connect'
    '--service-principal-id', $ServicePrincipalId
    '--service-principal-secret', $ServicePrincipalSecret
    '--tenant-id', $TenantId
    '--subscription-id', $SubscriptionId
    '--resource-group', $ResourceGroupName
    '--location', $Location
)
if ($ResourceName) {
    $connectArgs += '--resource-name'
    $connectArgs += $ResourceName
}

& $agentExe @connectArgs
if ($LASTEXITCODE -eq 0) {
    Write-Output '  Arc connection succeeded'
} else {
    Write-Output "  Arc connection failed (ExitCode: $LASTEXITCODE)"
}

Write-Output '=== Arc Agent Setup Completed ==='
