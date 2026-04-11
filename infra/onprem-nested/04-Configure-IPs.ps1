# 04 - Configure static IPs on nested VMs (run after OOBE completion)
. "$PSScriptRoot\_Invoke-OnHost.ps1"
Invoke-OnHost -ScriptFile 'scripts\Configure-StaticIPs.ps1' -StepName 'Configure Static IPs'
