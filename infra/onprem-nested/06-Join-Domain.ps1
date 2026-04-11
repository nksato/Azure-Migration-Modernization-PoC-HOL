# 06 - Join vm-app01 and vm-sql01 to contoso.local domain
. "$PSScriptRoot\_Invoke-OnHost.ps1"
Invoke-OnHost -ScriptFile 'scripts\host\Join-Domain.ps1' -StepName 'Join Domain'
