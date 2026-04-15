# =============================================================================
# Join-Domain.ps1
# Run on Hyper-V host: Join vm-app01 and vm-sql01 to contoso.local
# Prerequisites: Install-ADDS.ps1 completed and vm-ad01 has rebooted
# =============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$localPassword = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$localCred = New-Object System.Management.Automation.PSCredential('.\Administrator', $localPassword)

$domainPassword = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$domainCred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $domainPassword)

$domainName = 'contoso.local'

# Step 0: Verify DC is ready
Write-Host "=== Verifying Domain Controller (vm-ad01) ==="
$dcReady = $false
$retries = 0
$maxRetries = 10

while (-not $dcReady -and $retries -lt $maxRetries) {
    try {
        $result = Invoke-Command -VMName 'vm-ad01' -Credential $domainCred -ScriptBlock {
            (Get-ADDomainController -ErrorAction Stop).HostName
        } -ErrorAction Stop
        Write-Host "  DC is ready: $result"
        $dcReady = $true
    } catch {
        $retries++
        Write-Host "  DC not ready yet (attempt $retries/$maxRetries). Waiting 30 seconds..."
        Start-Sleep -Seconds 30
    }
}

if (-not $dcReady) {
    throw "Domain Controller is not ready after $maxRetries attempts. Wait and retry."
}

# Step 1: Update DHCP DNS option on Hyper-V host
Write-Host ""
Write-Host "=== Updating DHCP DNS option to point to DC ==="
Set-DhcpServerv4OptionValue -DnsServer 192.168.100.10
Write-Host "  DHCP DNS set to 192.168.100.10"

# Step 2: Join VMs to domain
$joinVMs = @('vm-app01', 'vm-sql01')

foreach ($vmName in $joinVMs) {
    Write-Host ""
    Write-Host "=== Joining $vmName to $domainName ==="

    Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
        param($Domain, $DomCred)

        # Verify DNS resolution
        $dns = Resolve-DnsName $Domain -ErrorAction SilentlyContinue
        if (-not $dns) {
            Write-Host "  WARNING: Cannot resolve $Domain. Attempting join anyway..."
        } else {
            Write-Host "  DNS resolution OK: $($dns[0].IPAddress)"
        }

        Add-Computer -DomainName $Domain -Credential $DomCred -Restart -Force
        Write-Host "  $env:COMPUTERNAME joined to $Domain. Rebooting..."
    } -ArgumentList $domainName, $domainCred

    Write-Host "  $vmName join initiated."
}

Write-Host ""
Write-Host "=== Domain join complete ==="
Write-Host "Both VMs are rebooting. After reboot, log in with CONTOSO\Administrator."
