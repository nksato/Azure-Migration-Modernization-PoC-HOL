# 05 - Install AD DS and promote vm-ad01 to Domain Controller
. "$PSScriptRoot\_Invoke-OnHost.ps1"
Invoke-OnHost -ScriptFile 'scripts\host\Install-ADDS.ps1' -StepName 'Install AD DS'
