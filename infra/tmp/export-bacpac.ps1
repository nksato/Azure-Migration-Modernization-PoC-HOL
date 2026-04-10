# vm-onprem-sql で BACPAC を作成し、Azure Storage にアップロードするスクリプト
param(
    [string]$StorageAccountName = 'stspoke4migrate',
    [string]$StorageAccountKey,
    [string]$ContainerName = 'bacpac',
    [string]$BlobName = 'PartsUnlimitedWebsite.bacpac',
    [string]$DatabaseName = 'PartsUnlimitedWebsite',
    [string]$SqlServer = 'localhost',
    [string]$SqlUser = 'sqladmin',
    [string]$SqlPassword = 'P@ssw0rd1234!'
)

$ErrorActionPreference = 'Stop'
$bacpacPath = "C:\temp\$BlobName"

# 1. SqlPackage を探す（既知のパスのみチェック）
$sqlPackagePaths = @(
    'C:\Program Files\Microsoft SQL Server\160\DAC\bin\SqlPackage.exe',
    'C:\Program Files\Microsoft SQL Server\150\DAC\bin\SqlPackage.exe',
    'C:\Program Files (x86)\Microsoft SQL Server\160\DAC\bin\SqlPackage.exe',
    'C:\Program Files (x86)\Microsoft SQL Server\150\DAC\bin\SqlPackage.exe',
    'C:\Program Files\Microsoft SQL Server\140\DAC\bin\SqlPackage.exe',
    'C:\sqlpackage\SqlPackage.exe'
)

$sqlPackage = $null
foreach ($p in $sqlPackagePaths) {
    if (Test-Path $p) { $sqlPackage = $p; break }
}

# SqlPackage がなければダウンロード
if (-not $sqlPackage) {
    Write-Output 'SqlPackage not found. Downloading...'
    $zipUrl = 'https://go.microsoft.com/fwlink/?linkid=2261576'
    $zipPath = 'C:\temp\sqlpackage.zip'
    $extractPath = 'C:\sqlpackage'
    New-Item -ItemType Directory -Path 'C:\temp' -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    $sqlPackage = Join-Path $extractPath 'SqlPackage.exe'
}

Write-Output "Using SqlPackage: $sqlPackage"

# 2. BACPAC エクスポート
New-Item -ItemType Directory -Path 'C:\temp' -Force | Out-Null
Write-Output "Exporting BACPAC from $SqlServer/$DatabaseName..."
& $sqlPackage /Action:Export `
    /SourceServerName:$SqlServer `
    /SourceDatabaseName:$DatabaseName `
    /SourceUser:$SqlUser `
    /SourcePassword:$SqlPassword `
    /SourceTrustServerCertificate:True `
    /TargetFile:$bacpacPath

if ($LASTEXITCODE -ne 0) { throw "SqlPackage export failed with exit code $LASTEXITCODE" }
Write-Output "BACPAC exported: $bacpacPath ($(( Get-Item $bacpacPath).Length / 1MB) MB)"

# 3. Azure Storage にアップロード（azcopy or REST API）
Write-Output 'Uploading to Azure Storage...'
$blobUrl = "https://${StorageAccountName}.blob.core.windows.net/${ContainerName}/${BlobName}"

# Az.Storage モジュールがあれば使う、なければ REST API
try {
    Import-Module Az.Storage -ErrorAction Stop
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
    Set-AzStorageBlobContent -File $bacpacPath -Container $ContainerName -Blob $BlobName -Context $ctx -Force
    Write-Output "Upload complete: $blobUrl"
} catch {
    Write-Output "Az.Storage not available, using REST API..."
    # REST API でアップロード
    $fileBytes = [System.IO.File]::ReadAllBytes($bacpacPath)
    $date = [DateTime]::UtcNow.ToString('R')
    $version = '2020-10-02'
    $contentLength = $fileBytes.Length
    
    $stringToSign = "PUT`n`n`n$contentLength`n`napplication/octet-stream`n`n`n`n`n`n`nx-ms-blob-type:BlockBlob`nx-ms-date:${date}`nx-ms-version:${version}`n/${StorageAccountName}/${ContainerName}/${BlobName}"
    
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Convert]::FromBase64String($StorageAccountKey)
    $sig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign)))
    $authHeader = "SharedKey ${StorageAccountName}:${sig}"
    
    $headers = @{
        'Authorization' = $authHeader
        'x-ms-date' = $date
        'x-ms-version' = $version
        'x-ms-blob-type' = 'BlockBlob'
        'Content-Type' = 'application/octet-stream'
    }
    
    Invoke-RestMethod -Uri $blobUrl -Method PUT -Headers $headers -Body $fileBytes
    Write-Output "Upload complete (REST): $blobUrl"
}
