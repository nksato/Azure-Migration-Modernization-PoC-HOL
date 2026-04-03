# ============================================================
# DC01 セットアップスクリプト
# AD DS / DNS のインストールと構成
# ============================================================

$ErrorActionPreference = 'Stop'

# AD DS と DNS の役割をインストール
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

# ドメインの作成
$securePassword = ConvertTo-SecureString 'P@ssw0rd1234!' -AsPlainText -Force
Install-ADDSForest `
    -DomainName 'contoso.local' `
    -DomainNetBIOSName 'CONTOSO' `
    -ForestMode 'WinThreshold' `
    -DomainMode 'WinThreshold' `
    -SafeModeAdministratorPassword $securePassword `
    -InstallDns:$true `
    -NoRebootOnCompletion:$false `
    -Force:$true

# 再起動後に AD DS が起動するため、OU とサービスアカウントの作成は
# 再起動後のスクリプトで実行する（下記は再起動後に手動実行、またはスケジュールタスクで実行）

# OU 作成とサービスアカウント作成用スクリプトをスケジュール
$postSetupScript = @'
Import-Module ActiveDirectory
New-ADOrganizationalUnit -Name "Servers" -Path "DC=contoso,DC=local" -ErrorAction SilentlyContinue
New-ADOrganizationalUnit -Name "ServiceAccounts" -Path "DC=contoso,DC=local" -ErrorAction SilentlyContinue
New-ADUser -Name "svc-webapp" -Path "OU=ServiceAccounts,DC=contoso,DC=local" -AccountPassword (ConvertTo-SecureString 'P@ssw0rd1234!' -AsPlainText -Force) -Enabled $true -PasswordNeverExpires $true -ErrorAction SilentlyContinue
New-ADUser -Name "svc-sqlserver" -Path "OU=ServiceAccounts,DC=contoso,DC=local" -AccountPassword (ConvertTo-SecureString 'P@ssw0rd1234!' -AsPlainText -Force) -Enabled $true -PasswordNeverExpires $true -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "PostADSetup" -Confirm:$false -ErrorAction SilentlyContinue
'@

$postSetupScript | Out-File -FilePath 'C:\PostADSetup.ps1' -Encoding utf8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Unrestricted -File C:\PostADSetup.ps1'
$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Minutes 2)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName 'PostADSetup' -Action $action -Trigger $trigger -Principal $principal
