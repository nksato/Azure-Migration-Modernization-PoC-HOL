# 01 - Setup nested VM network (NAT + DHCP)
. "$PSScriptRoot\_Invoke-OnHost.ps1"
Invoke-OnHost -ScriptFile 'scripts\host\Setup-NestedNetwork.ps1' -StepName 'Setup Network (NAT + DHCP)'
