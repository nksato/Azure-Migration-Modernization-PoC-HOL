# 02 - Create nested VMs (async - VHDX conversion takes several minutes)
. "$PSScriptRoot\_Invoke-OnHost.ps1"
Invoke-OnHost -ScriptFile 'scripts\Create-NestedVMs.ps1' -StepName 'CreateNestedVMs' -Async
