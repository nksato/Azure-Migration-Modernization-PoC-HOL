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
        param($IP, $DNS, $DesiredName)

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

        # Enable ICMP (ping)
        Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue

        # Enable Remote Desktop
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue

        # Rename computer if hostname doesn't match Hyper-V VM name
        if ($env:COMPUTERNAME -ne $DesiredName) {
            Rename-Computer -NewName $DesiredName -Force
            Write-Host "  Renamed: $env:COMPUTERNAME -> $DesiredName (reboot required)"
        }

        Write-Host "  IP: $IP, DNS: $DNS, ICMP: enabled, RDP: enabled on $ifAlias"
    } -ArgumentList $vm.IP, $vm.DNS, $vm.Name

    Write-Host "  $($vm.Name) done."
}

Write-Host ""
Write-Host "=== Static IP configuration complete ==="

# Enable ICMP on host (for gateway ping from nested VMs)
Write-Host "  Enabling ICMP on host..."
Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue

# Verify connectivity from host
foreach ($vm in $vmConfigs) {
    $result = Test-Connection -ComputerName $vm.IP -Count 1 -Quiet
    Write-Host "  Ping $($vm.Name) ($($vm.IP)): $(if ($result) { 'OK' } else { 'FAIL' })"
}

# Restart VMs to apply hostname changes (Rename-Computer requires reboot)
Write-Host ""
Write-Host "=== Applying hostname changes ==="
$needsRestart = $false
foreach ($vm in $vmConfigs) {
    $actualName = Invoke-Command -VMName $vm.Name -Credential $cred -ScriptBlock { $env:COMPUTERNAME }
    if ($actualName -ne $vm.Name) {
        Write-Host "  $($vm.Name): pending rename ($actualName -> $($vm.Name)). Restarting..."
        Restart-VM -Name $vm.Name -Force
        $needsRestart = $true
    } else {
        Write-Host "  $($vm.Name): hostname OK ($actualName)"
    }
}

if ($needsRestart) {
    Write-Host "  Waiting for VMs to restart..."
    Start-Sleep -Seconds 15
    foreach ($vm in $vmConfigs) {
        $timeout = 120; $elapsed = 0
        while ($elapsed -lt $timeout) {
            try {
                $name = Invoke-Command -VMName $vm.Name -Credential $cred `
                    -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
                Write-Host "  $($vm.Name): online (hostname: $name)"
                break
            } catch {
                Start-Sleep -Seconds 5; $elapsed += 5
            }
        }
        if ($elapsed -ge $timeout) {
            Write-Host "  $($vm.Name): not responding after ${timeout}s" -ForegroundColor Yellow
        }
    }
}
