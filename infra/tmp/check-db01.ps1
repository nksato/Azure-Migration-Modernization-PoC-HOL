# DB01 上の SqlPackage とデータベースを確認するスクリプト
Get-ChildItem -Path 'C:\Program Files*' -Recurse -Filter 'SqlPackage.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 3 -ExpandProperty FullName

try {
    $dbs = Invoke-Sqlcmd -ServerInstance 'localhost' -Username 'sqladmin' -Password 'P@ssw0rd1234!' -Query 'SELECT name FROM sys.databases' -TrustServerCertificate
    $dbs | ForEach-Object { Write-Output ("DB: " + $_.name) }
} catch {
    Write-Output "SqlCmd error: $_"
}
