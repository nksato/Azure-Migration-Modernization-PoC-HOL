param(
    [Parameter(Mandatory)]
    [string]$AppName,

    [string]$ResourceGroup = "rg-spoke4",

    [string]$BannerText = "CLOUD",

    [string]$BannerColor = "#2e7d32"
)

# App Service の発行資格情報を取得
$creds = az webapp deployment list-publishing-credentials -g $ResourceGroup -n $AppName --query "{user:publishingUserName, pass:publishingPassword}" -o json | ConvertFrom-Json

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($creds.user):$($creds.pass)"))
$kuduBase = "https://$AppName.scm.azurewebsites.net/api/vfs/site/wwwroot"

# _Layout.cshtml を検索
$headers = @{ Authorization = "Basic $base64Auth"; "If-Match" = "*" }
$layoutPath = "Views/Shared/_Layout.cshtml"
$url = "$kuduBase/$layoutPath"

Write-Host "Downloading _Layout.cshtml from $url ..." -ForegroundColor Yellow
$content = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Basic $base64Auth" } -Method GET

$banner = "<div style=`"background:$BannerColor;color:white;text-align:center;padding:8px;font-size:18px;font-weight:bold;position:fixed;top:0;left:0;right:0;z-index:9999`">$BannerText</div><div style=`"height:40px`"></div>"

if ($content -notmatch $BannerText) {
    $content = $content -replace '(<body[^>]*>)', "`$1$banner"
    
    Write-Host "Uploading modified _Layout.cshtml ..." -ForegroundColor Yellow
    Invoke-RestMethod -Uri $url -Headers $headers -Method PUT -Body $content -ContentType "text/plain"
    Write-Host "CLOUD banner added successfully." -ForegroundColor Green
} else {
    Write-Host "Banner already exists." -ForegroundColor Yellow
}
