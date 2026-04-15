# =============================================================================
# Install-ADDS.ps1
# Run on Hyper-V host: Install AD DS on vm-ad01 and promote to DC
# Domain: contoso.local
# After promotion, vm-ad01 will reboot automatically
# =============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$password = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('.\Administrator', $password)

$domainName = 'contoso.local'
$netbiosName = 'CONTOSO'

Write-Host "=== Installing AD DS on vm-ad01 ==="
Write-Host "  Domain: $domainName"
Write-Host "  NetBIOS: $netbiosName"
Write-Host ""

# Pre-check: Verify hostname matches Hyper-V VM name
$actualHostname = Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock { $env:COMPUTERNAME }
if ($actualHostname -ne 'vm-ad01') {
    throw "vm-ad01 hostname is '$actualHostname', expected 'vm-ad01'. Run Configure-StaticIPs.ps1 and ensure VM was restarted."
}
Write-Host "  Hostname: $actualHostname (OK)"
Write-Host ""

# Step 1: Install AD DS role
Write-Host "[1/2] Installing AD DS role..."
Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
    if ((Get-WindowsFeature AD-Domain-Services).Installed) {
        Write-Host "  AD DS role already installed."
    } else {
        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
        Write-Host "  AD DS role installed."
    }
}

# Step 2: Promote to Domain Controller
Write-Host "[2/2] Promoting to Domain Controller..."
Write-Host "  vm-ad01 will reboot after promotion."

Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
    param($DomainName, $NetBIOSName, $SafeModePass)

    Import-Module ADDSDeployment

    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $NetBIOSName `
        -SafeModeAdministratorPassword $SafeModePass `
        -InstallDns:$true `
        -NoRebootOnCompletion:$false `
        -Force:$true
} -ArgumentList $domainName, $netbiosName, $password

Write-Host ""
Write-Host "=== AD DS promotion initiated ==="
Write-Host "vm-ad01 is rebooting. Wait 3-5 minutes before running Join-Domain.ps1"
