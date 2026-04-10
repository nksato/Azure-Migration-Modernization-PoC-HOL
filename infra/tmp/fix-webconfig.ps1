Add-Type -AssemblyName System.IO.Compression.FileSystem

# 元 ZIP を展開
Remove-Item 'C:\temp\appfull3' -Recurse -Force -EA SilentlyContinue
[IO.Compression.ZipFile]::ExtractToDirectory('C:\temp\app-orig.zip', 'C:\temp\appfull3')

$f = 'C:\temp\appfull3\Web.config'
$c = Get-Content $f -Raw

# 1. 接続文字列を Azure SQL に変更
$c = $c.Replace(
    'Server=10.0.1.5;Database=PartsUnlimitedWebsite;User Id=puadmin;Password=P@ssw0rd1234;TrustServerCertificate=True;',
    'Server=tcp:sql-spoke4-aa18e53c.database.windows.net,1433;Database=sqldb-spoke4;User Id=sqladmin;Password=MigrateP0C2026x;Encrypt=True;TrustServerCertificate=True;'
)

# 2. customErrors Off
$c = $c.Replace('customErrors mode="RemoteOnly"', 'customErrors mode="Off"')

# 3. httpErrors Detailed
$c = $c.Replace('</system.webServer>', '  <httpErrors errorMode="Detailed" />' + "`r`n" + '  </system.webServer>')

# 4. EF NullDatabaseInitializer
$efCtx = @"

    <contexts>
      <context type="PartsUnlimited.Models.PartsUnlimitedContext, PartsUnlimited">
        <databaseInitializer type="System.Data.Entity.NullDatabaseInitializer``1[[PartsUnlimited.Models.PartsUnlimitedContext, PartsUnlimited]], EntityFramework" />
      </context>
    </contexts>
"@
$c = $c.Replace('<entityFramework>', '<entityFramework>' + $efCtx)

Set-Content $f -Value $c -Encoding UTF8 -NoNewline

# ZIP 再作成
Remove-Item 'C:\temp\appfinal3.zip' -Force -EA SilentlyContinue
[IO.Compression.ZipFile]::CreateFromDirectory('C:\temp\appfull3', 'C:\temp\appfinal3.zip')
Write-Host ("Size: " + [Math]::Round((Get-Item 'C:\temp\appfinal3.zip').Length / 1MB, 2) + " MB")
