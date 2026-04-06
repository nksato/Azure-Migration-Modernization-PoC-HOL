# ============================================================
# Setup-ArcAgent-en.ps1
# Setup script to run inside VM for Azure Arc onboarding
# - Block IMDS endpoints (firewall rules)
# - Install Azure Connected Machine Agent
# - Disable Azure VM Guest Agent
# - Connect to Azure Arc via azcmagent
# ============================================================
# Usage (via az vm run-command):
#   az vm run-command invoke `
#     --resource-group rg-onprem --name vm-onprem-web `
#     --command-id RunPowerShellScript `
#     --scripts @infra/onprem/scripts/Setup-ArcAgent-en.ps1 `
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
# 1. Block IMDS endpoints
# ----------------------------------------------------------
Write-Output '[1/4] Blocking IMDS endpoints...'

$r1 = Get-NetFirewallRule -Name 'BlockAzureIMDS' -ErrorAction SilentlyContinue
if (-not $r1) {
    New-NetFirewallRule -Name 'BlockAzureIMDS' -DisplayName 'Block access to Azure IMDS' `
        -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254 | Out-Null
    Write-Output '  BlockAzureIMDS rule created.'
} else {
    Write-Output '  BlockAzureIMDS rule already exists.'
}

$r2 = Get-NetFirewallRule -Name 'BlockAzureIMDS_AzureLocal' -ErrorAction SilentlyContinue
if (-not $r2) {
    New-NetFirewallRule -Name 'BlockAzureIMDS_AzureLocal' -DisplayName 'Block access to Azure Local IMDS' `
        -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.253 | Out-Null
    Write-Output '  BlockAzureIMDS_AzureLocal rule created.'
} else {
    Write-Output '  BlockAzureIMDS_AzureLocal rule already exists.'
}

# ----------------------------------------------------------
# 2. Install Azure Connected Machine Agent
# ----------------------------------------------------------
Write-Output '[2/4] Installing Azure Connected Machine Agent...'

$agentExe = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
if (Test-Path $agentExe) {
    Write-Output '  Agent is already installed.'
} else {
    Write-Output '  Downloading agent...'
    $ProgressPreference = 'SilentlyContinue'
    $msi = Join-Path $env:TEMP 'install_windows_azcmagent.msi'
    Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $msi -UseBasicParsing
    Write-Output '  Installing agent...'
    $log = Join-Path $env:TEMP 'installationlog.txt'
    $exitCode = (Start-Process -FilePath msiexec.exe -ArgumentList '/i', $msi, '/l*v', $log, '/qn' -Wait -Passthru).ExitCode
    if ($exitCode -ne 0) {
        throw "Agent install failed (ExitCode: $exitCode). See log: $log"
    }
    Write-Output '  Agent installed successfully.'
}

# ----------------------------------------------------------
# 3. Disable Azure VM Guest Agent
# ----------------------------------------------------------
Write-Output '[3/4] Disabling Azure VM Guest Agent...'

Set-Service WindowsAzureGuestAgent -StartupType Disabled
Stop-Service WindowsAzureGuestAgent -Force
Write-Output '  WindowsAzureGuestAgent has been disabled.'

# ----------------------------------------------------------
# 4. Connect to Azure Arc
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
    Write-Output '  Arc connection succeeded.'
} else {
    Write-Output "  Arc connection failed (ExitCode: $LASTEXITCODE)."
}

Write-Output '=== Arc Agent Setup Completed ==='
