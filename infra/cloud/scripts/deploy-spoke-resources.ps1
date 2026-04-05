# ============================================================
# Spoke リソースデプロイ補助スクリプト
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('spoke1', 'spoke2', 'spoke3', 'spoke4')]
    [string]$Spoke,

    [Parameter(Mandatory=$true)]
    [string]$AdminUsername,

    [Parameter(Mandatory=$true)]
    [SecureString]$AdminPassword,

    [string]$SqlAdminLogin = 'sqladmin',

    [SecureString]$SqlAdminPassword
)

$ErrorActionPreference = 'Stop'

$templateRoot = Resolve-Path (Join-Path $PSScriptRoot '..\modules\spoke-resources')

$templateMap = @{
    'spoke1' = @{ rg = 'rg-spoke1'; template = (Join-Path $templateRoot 'spoke1-rehost.bicep') }
    'spoke2' = @{ rg = 'rg-spoke2'; template = (Join-Path $templateRoot 'spoke2-db-paas.bicep') }
    'spoke3' = @{ rg = 'rg-spoke3'; template = (Join-Path $templateRoot 'spoke3-container.bicep') }
    'spoke4' = @{ rg = 'rg-spoke4'; template = (Join-Path $templateRoot 'spoke4-full-paas.bicep') }
}

$config = $templateMap[$Spoke]

Write-Output "Deploying $Spoke resources to $($config.rg)..."

$params = @{
    adminUsername = $AdminUsername
    adminPassword = $AdminPassword
}

if ($Spoke -ne 'spoke1') {
    $params.sqlAdminLogin = $SqlAdminLogin
    $params.sqlAdminPassword = $SqlAdminPassword
}

az deployment group create `
    --resource-group $config.rg `
    --template-file $config.template `
    --parameters ($params | ConvertTo-Json -Compress)

Write-Output "$Spoke deployment completed."
