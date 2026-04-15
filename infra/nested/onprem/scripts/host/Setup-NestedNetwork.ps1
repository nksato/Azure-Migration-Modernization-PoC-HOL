# =============================================================================
# Setup-NestedNetwork.ps1
# Run on Hyper-V host VM: Configure internal NAT network and DHCP for nested VMs
# Connect via Bastion, then run in an elevated PowerShell session
# =============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# --- Configuration ---
$switchName     = 'InternalNAT'
$natName        = 'NestedVMNAT'
$gatewayIP      = '192.168.100.1'
$prefixLength   = 24
$natPrefix      = '192.168.100.0/24'
$dhcpScopeStart = '192.168.100.100'
$dhcpScopeEnd   = '192.168.100.200'
$dhcpSubnet     = '255.255.255.0'

# --- Create Internal VM Switch ---
Write-Host "[1/4] Creating Internal VM Switch: $switchName"
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $switchName -SwitchType Internal
    Write-Host "  VM Switch created."
} else {
    Write-Host "  VM Switch already exists. Skipping."
}

# --- Assign IP to the host-side adapter ---
Write-Host "[2/4] Assigning gateway IP: $gatewayIP"
$adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$switchName*" }
$existingIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $gatewayIP }

if (-not $existingIP) {
    New-NetIPAddress -IPAddress $gatewayIP -PrefixLength $prefixLength -InterfaceIndex $adapter.ifIndex
    Write-Host "  IP address assigned."
} else {
    Write-Host "  IP address already assigned. Skipping."
}

# --- Create NAT ---
Write-Host "[3/4] Creating NAT: $natName"
if (-not (Get-NetNat -Name $natName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $natPrefix
    Write-Host "  NAT created."
} else {
    Write-Host "  NAT already exists. Skipping."
}

# --- Configure DHCP scope ---
Write-Host "[4/4] Configuring DHCP scope"
$scopeExists = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
    Where-Object { $_.StartRange -eq $dhcpScopeStart }

if (-not $scopeExists) {
    Add-DhcpServerv4Scope -Name "NestedVMs" `
        -StartRange $dhcpScopeStart `
        -EndRange $dhcpScopeEnd `
        -SubnetMask $dhcpSubnet `
        -State Active

    Set-DhcpServerv4OptionValue `
        -Router $gatewayIP

    # DNS will be configured after AD DS is set up on vm-ad01 (192.168.100.10)
    # Set-DhcpServerv4OptionValue -DnsServer 192.168.100.10

    Write-Host "  DHCP scope configured (DNS will be set after AD DS setup)."
} else {
    Write-Host "  DHCP scope already exists. Skipping."
}

Write-Host ""
Write-Host "=== Setup complete ==="
Write-Host "Nested VMs should use the '$switchName' virtual switch."
Write-Host "DHCP range: $dhcpScopeStart - $dhcpScopeEnd"
Write-Host "Gateway:    $gatewayIP"
