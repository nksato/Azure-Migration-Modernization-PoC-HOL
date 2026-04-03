# ============================================================
# Azure Arc Agent インストールスクリプト
# Azure VM 上で Arc を動作させるため IMDS をブロック
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$true)]
    [string]$TenantId,

    [string]$Location = 'japaneast'
)

$ErrorActionPreference = 'Stop'

Write-Output '=== Azure Arc Agent Installation ==='

# Step 1: IMDS エンドポイントをブロック（Azure VM で Arc を動作させるために必須）
Write-Output 'Step 1: Blocking IMDS endpoint...'
$existingRule = Get-NetFirewallRule -Name 'BlockIMDS' -ErrorAction SilentlyContinue
if (-not $existingRule) {
    New-NetFirewallRule -Name 'BlockIMDS' -DisplayName 'Block IMDS for Azure Arc' `
        -Direction Outbound -RemoteAddress 169.254.169.254 -Action Block
    Write-Output 'IMDS blocked successfully.'
} else {
    Write-Output 'IMDS block rule already exists.'
}

# Step 2: Azure Arc Connected Machine Agent のダウンロードとインストール
Write-Output 'Step 2: Downloading Azure Arc agent...'
$agentInstaller = "$env:TEMP\install_windows_azcmagent.ps1"
Invoke-WebRequest -Uri 'https://aka.ms/azcmagent-windows' -OutFile $agentInstaller
& $agentInstaller

# Step 3: Arc に接続
Write-Output 'Step 3: Connecting to Azure Arc...'
& "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe" connect `
    --resource-group $ResourceGroup `
    --tenant-id $TenantId `
    --location $Location `
    --subscription-id $SubscriptionId `
    --tags "Environment=PoC,Project=Migration-Handson,SecurityControl=Ignore"

Write-Output '=== Azure Arc Agent installation completed ==='
Write-Output 'Verify in Azure Portal: Azure Arc > Servers'
