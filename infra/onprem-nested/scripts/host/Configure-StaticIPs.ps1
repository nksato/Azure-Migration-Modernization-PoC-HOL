# =============================================================================
# Configure-StaticIPs.ps1
# Run on Hyper-V host: Set static IPs on nested VMs via PowerShell Direct
# =============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$password = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('.\Administrator', $password)

$vmConfigs = @(
    @{ Name = 'vm-ad01';  IP = '192.168.100.10'; DNS = '127.0.0.1' }
    @{ Name = 'vm-app01'; IP = '192.168.100.11'; DNS = '192.168.100.10' }
    @{ Name = 'vm-sql01'; IP = '192.168.100.12'; DNS = '192.168.100.10' }
)

foreach ($vm in $vmConfigs) {
    Write-Host "=== Configuring $($vm.Name): $($vm.IP) ==="

    Invoke-Command -VMName $vm.Name -Credential $cred -ScriptBlock {
        param($IP, $DNS)

        # Find the active Ethernet adapter
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        $ifAlias = $adapter.Name

        # Remove existing DHCP IP
        $currentIP = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($currentIP) {
            Remove-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceAlias $ifAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Set static IP
        New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $IP -PrefixLength 24 -DefaultGateway '192.168.100.1'
        Set-DnsClientServerAddress -InterfaceAlias $ifAlias -ServerAddresses $DNS

        # Disable DHCP
        Set-NetIPInterface -InterfaceAlias $ifAlias -Dhcp Disabled -ErrorAction SilentlyContinue

        Write-Host "  IP: $IP, DNS: $DNS configured on $ifAlias"
    } -ArgumentList $vm.IP, $vm.DNS

    Write-Host "  $($vm.Name) done."
}

Write-Host ""
Write-Host "=== Static IP configuration complete ==="

# Verify connectivity from host
foreach ($vm in $vmConfigs) {
    $result = Test-Connection -ComputerName $vm.IP -Count 1 -Quiet
    Write-Host "  Ping $($vm.Name) ($($vm.IP)): $(if ($result) { 'OK' } else { 'FAIL' })"
}
