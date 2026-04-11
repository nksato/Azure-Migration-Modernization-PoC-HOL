<#
.SYNOPSIS
    Nested Hyper-V on-prem environment setup verification
.DESCRIPTION
    Validates Azure resources, Hyper-V host configuration, and nested VM setup
    using Azure CLI and az vm run-command invoke (+ PowerShell Direct for guests).
    Bastion connection is NOT required.
.EXAMPLE
    .\Verify-OnpremSetup.ps1
.EXAMPLE
    .\Verify-OnpremSetup.ps1 -SkipNestedVMs
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-onprem-nested',
    [string]$HostVmName = 'vm-onprem-nested-hv01',
    [string]$VnetName = 'vnet-onprem-nested',
    [switch]$SkipNestedVMs
)

$ErrorActionPreference = 'Continue'
$total = 0; $passed = 0

# =============================================================================
# Helpers
# =============================================================================

function Invoke-HostCommand ([string]$Script) {
    $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
    try {
        $Script | Set-Content -Path $tmpFile -Encoding UTF8
        $jsonText = az vm run-command invoke `
            --resource-group $ResourceGroupName --name $HostVmName `
            --command-id RunPowerShellScript --scripts "@$tmpFile" -o json 2>$null
        if (-not $jsonText) { Write-Host "         ERROR: run-command returned no output" -ForegroundColor Red; return '' }
        $r = ($jsonText -join '') | ConvertFrom-Json
        $stderr = ($r.value | Where-Object { $_.code -like '*stderr*' }).message
        if ($stderr) { Write-Host "         stderr: $stderr" -ForegroundColor DarkYellow }
        ($r.value | Where-Object { $_.code -like '*stdout*' }).message
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-Val ([string]$Output, [string]$Key) {
    $line = ($Output -split "`n") | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($line) { ($line -replace "^${Key}=", '').Trim() } else { '' }
}

function Test-Val ([string]$Label, [string]$Actual, [string]$Expected) {
    $ok = $Actual -eq $Expected
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Label, $Actual) -ForegroundColor $color
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-NotEmpty ([string]$Label, [string]$Actual) {
    $ok = -not [string]::IsNullOrWhiteSpace($Actual)
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $Label, $(if ($ok) { $Actual } else { '(not found)' })) -ForegroundColor $color
    $script:total++; if ($ok) { $script:passed++ }
}

function Test-Bool ([string]$Label, [bool]$Value) {
    $color = if ($Value) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $(if ($Value) { 'PASS' } else { 'FAIL' }), $Label) -ForegroundColor $color
    $script:total++; if ($Value) { $script:passed++ }
}

# =============================================================================
# 1. Resource Group & Common Resources
# =============================================================================
Write-Host "`n=== 1. Resource Group & Common Resources ===" -ForegroundColor Cyan

$rgExists = az group exists -n $ResourceGroupName -o tsv 2>$null
Test-Val $ResourceGroupName $rgExists 'true'

if ($rgExists -ne 'true') {
    Write-Host "`n  Resource group not found. Verify deployment." -ForegroundColor Red
    Write-Host ("`nResult: {0}/{1} passed" -f $passed, $total) -ForegroundColor Yellow
    exit 1
}

$bastionState = az network bastion show -g $ResourceGroupName -n 'bas-onprem-nested' `
    --query 'provisioningState' -o tsv 2>$null
Test-Val 'bas-onprem-nested (Bastion)' $bastionState 'Succeeded'

# =============================================================================
# 2. VNet & Subnet & NSG
# =============================================================================
Write-Host "`n=== 2. VNet & Subnet ===" -ForegroundColor Cyan

$vnetAddr = az network vnet show -g $ResourceGroupName -n $VnetName `
    --query 'addressSpace.addressPrefixes[0]' -o tsv 2>$null
Test-Val $VnetName $vnetAddr '10.1.0.0/16'

foreach ($snet in @('snet-onprem-nested', 'AzureBastionSubnet')) {
    $prefix = az network vnet subnet show -g $ResourceGroupName --vnet-name $VnetName -n $snet `
        --query 'addressPrefix' -o tsv 2>$null
    Test-NotEmpty "$VnetName/$snet" $prefix
}

$nsgName = az network nsg show -g $ResourceGroupName -n 'nsg-onprem-nested' --query 'name' -o tsv 2>$null
Test-NotEmpty 'nsg-onprem-nested' $nsgName

# NAT Gateway
$ngName = az network nat gateway show -g $ResourceGroupName -n 'ng-onprem-nested' --query 'name' -o tsv 2>$null
Test-NotEmpty 'ng-onprem-nested' $ngName

# =============================================================================
# 3. Host VM
# =============================================================================
Write-Host "`n=== 3. Host VM ===" -ForegroundColor Cyan

$vmState = az vm get-instance-view -g $ResourceGroupName -n $HostVmName `
    --query "instanceView.statuses[?code=='PowerState/running'].displayStatus | [0]" -o tsv 2>$null
Test-Val $HostVmName $vmState 'VM running'

# No public IP
$nicPip = az network nic show -g $ResourceGroupName -n "nic-$HostVmName" `
    --query 'ipConfigurations[].publicIPAddress.id' -o tsv 2>$null
$hasPip = -not [string]::IsNullOrWhiteSpace($nicPip)
Test-Bool "${HostVmName}: No Public IP" (-not $hasPip)

$vmSize = az vm show -g $ResourceGroupName -n $HostVmName `
    --query 'hardwareProfile.vmSize' -o tsv 2>$null
Test-NotEmpty "$HostVmName VM size" $vmSize

# =============================================================================
# 4. Host: Hyper-V / NAT / DHCP
# =============================================================================
Write-Host "`n=== 4. Host: Hyper-V / NAT / DHCP ===" -ForegroundColor Cyan
Write-Host "  Running remote commands..." -ForegroundColor Gray

$hostOut = Invoke-HostCommand @'
Write-Output ('HYPERV=' + (Get-WindowsFeature Hyper-V).InstallState)
Write-Output ('DHCP=' + (Get-WindowsFeature DHCP).InstallState)
$sw = Get-VMSwitch -Name 'InternalNAT' -ErrorAction SilentlyContinue
Write-Output ('VMSWITCH=' + $(if ($sw) { $sw.SwitchType } else { '' }))
$nat = Get-NetNat -Name 'NestedVMNAT' -ErrorAction SilentlyContinue
Write-Output ('NAT=' + $(if ($nat) { $nat.InternalIPInterfaceAddressPrefix } else { '' }))
$adapter = Get-NetAdapter | Where-Object { $_.Name -like '*InternalNAT*' } | Select-Object -First 1
if ($adapter) { $ip = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress } else { $ip = '' }
Write-Output ('GATEWAY_IP=' + $ip)
$scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Output ('DHCP_SCOPE=' + $(if ($scope) { "$($scope.StartRange)-$($scope.EndRange)" } else { '' }))
$dnsOpt = (Get-DhcpServerv4OptionValue -OptionId 6 -ErrorAction SilentlyContinue).Value -join ','
Write-Output ('DHCP_DNS=' + $dnsOpt)
$dataDisk = Test-Path 'F:\Hyper-V'
Write-Output ('DATA_DISK=' + $dataDisk)
'@

Test-Val  'Hyper-V role'               (Get-Val $hostOut 'HYPERV')     'Installed'
Test-Val  'DHCP role'                  (Get-Val $hostOut 'DHCP')       'Installed'
Test-Val  'InternalNAT switch'         (Get-Val $hostOut 'VMSWITCH')   'Internal'
Test-Val  'NAT (192.168.100.0/24)'     (Get-Val $hostOut 'NAT')        '192.168.100.0/24'
Test-Val  'Gateway IP'                 (Get-Val $hostOut 'GATEWAY_IP') '192.168.100.1'
Test-NotEmpty 'DHCP scope'             (Get-Val $hostOut 'DHCP_SCOPE')
Test-NotEmpty 'DHCP DNS option'        (Get-Val $hostOut 'DHCP_DNS')
Test-Val  'Data disk (F:\Hyper-V)'     (Get-Val $hostOut 'DATA_DISK')  'True'

# =============================================================================
# 5. Nested VMs - Status
# =============================================================================
Write-Host "`n=== 5. Nested VMs ===" -ForegroundColor Cyan

if ($SkipNestedVMs) {
    Write-Host "  [SKIP] -SkipNestedVMs specified" -ForegroundColor DarkGray
} else {
    Write-Host "  Running remote commands..." -ForegroundColor Gray

    $vmOut = Invoke-HostCommand @'
foreach ($name in @('vm-ad01','vm-app01','vm-sql01')) {
    $v = Get-VM -Name $name -ErrorAction SilentlyContinue
    if ($v) {
        Write-Output ("VM_${name}_STATE=" + $v.State)
        Write-Output ("VM_${name}_CPU=" + $v.ProcessorCount)
        Write-Output ("VM_${name}_MEM=" + [math]::Round($v.MemoryStartup / 1GB))
    } else {
        Write-Output ("VM_${name}_STATE=NotFound")
    }
}
'@

    foreach ($vm in @('vm-ad01', 'vm-app01', 'vm-sql01')) {
        $state = Get-Val $vmOut "VM_${vm}_STATE"
        Test-Val "$vm state" $state 'Running'
        $cpu = Get-Val $vmOut "VM_${vm}_CPU"
        Test-NotEmpty "$vm CPU" $cpu
        $mem = Get-Val $vmOut "VM_${vm}_MEM"
        Test-NotEmpty "$vm Memory (GB)" $mem
    }

    # =========================================================================
    # 6. Nested VMs - Static IPs
    # =========================================================================
    Write-Host "`n=== 6. Nested VMs: Static IP ===" -ForegroundColor Cyan
    Write-Host "  Running remote commands (PowerShell Direct)..." -ForegroundColor Gray

    $ipOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$localCred = New-Object System.Management.Automation.PSCredential('.\Administrator', $pw)
$domainCred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
foreach ($item in @(
    @{Name='vm-ad01'; IP='192.168.100.10'},
    @{Name='vm-app01'; IP='192.168.100.11'},
    @{Name='vm-sql01'; IP='192.168.100.12'}
)) {
    $cred = $domainCred
    try {
        $r = Invoke-Command -VMName $item.Name -Credential $cred -ScriptBlock {
            $a = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
            $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop
            $dns = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses -join ','
            Write-Output "IP=$ip"
            Write-Output "GW=$gw"
            Write-Output "DNS=$dns"
        } -ErrorAction Stop
        foreach ($line in ($r -split "`n")) {
            if ($line -match '^(IP|GW|DNS)=') { Write-Output ($item.Name + '_' + $line.Trim()) }
        }
    } catch {
        try {
            $r = Invoke-Command -VMName $item.Name -Credential $localCred -ScriptBlock {
                $a = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
                $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
                Write-Output "IP=$ip"
            } -ErrorAction Stop
            foreach ($line in ($r -split "`n")) {
                if ($line -match '^IP=') { Write-Output ($item.Name + '_' + $line.Trim()) }
            }
            Write-Output ($item.Name + '_DOMAIN_CRED=FAIL')
        } catch {
            Write-Output ($item.Name + '_IP=ERROR')
        }
    }
}
'@

    $expectedIPs = @{ 'vm-ad01' = '192.168.100.10'; 'vm-app01' = '192.168.100.11'; 'vm-sql01' = '192.168.100.12' }
    foreach ($vm in @('vm-ad01', 'vm-app01', 'vm-sql01')) {
        $ip = Get-Val $ipOut "${vm}_IP"
        Test-Val "$vm IP" $ip $expectedIPs[$vm]
    }

    # Host ping to nested VMs
    Write-Host "`n  Host -> Nested VM ping:" -ForegroundColor Gray
    $pingOut = Invoke-HostCommand @'
foreach ($ip in @('192.168.100.10','192.168.100.11','192.168.100.12')) {
    $r = Test-Connection -ComputerName $ip -Count 1 -Quiet
    Write-Output "PING_${ip}=$r"
}
'@

    foreach ($item in @(
        @{ vm = 'vm-ad01';  ip = '192.168.100.10' },
        @{ vm = 'vm-app01'; ip = '192.168.100.11' },
        @{ vm = 'vm-sql01'; ip = '192.168.100.12' }
    )) {
        $ping = Get-Val $pingOut "PING_$($item.ip)"
        Test-Val "Host -> $($item.vm) ($($item.ip))" $ping 'True'
    }

    # =========================================================================
    # 7. vm-ad01: Active Directory + DNS
    # =========================================================================
    Write-Host "`n=== 7. vm-ad01: Active Directory + DNS ===" -ForegroundColor Cyan
    Write-Host "  Running remote commands (PowerShell Direct)..." -ForegroundColor Gray

    $adOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
try {
    $r = Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
        $d = Get-ADDomain -ErrorAction Stop
        Write-Output ('DOMAIN=' + $d.DNSRoot)
        Write-Output ('NETBIOS=' + $d.NetBIOSName)
        Write-Output ('PDC=' + $d.PDCEmulator)
        $z = Get-DnsServerZone -Name $d.DNSRoot -ErrorAction SilentlyContinue
        Write-Output ('DNSZONE=' + $z.ZoneName)
        Write-Output ('ADDS=' + (Get-WindowsFeature AD-Domain-Services).InstallState)
        Write-Output ('DNS_ROLE=' + (Get-WindowsFeature DNS).InstallState)
    } -ErrorAction Stop
    $r | ForEach-Object { Write-Output $_ }
} catch {
    Write-Output "DOMAIN=ERROR: $($_.Exception.Message)"
}
'@

    $adDomain = Get-Val $adOut 'DOMAIN'
    Test-Val      'AD Domain'            $adDomain          'contoso.local'
    Test-Val      'NetBIOS'              (Get-Val $adOut 'NETBIOS')    'CONTOSO'
    Test-NotEmpty 'PDC Emulator'         (Get-Val $adOut 'PDC')
    Test-Val      'DNS Zone'             (Get-Val $adOut 'DNSZONE')    'contoso.local'
    Test-Val      'AD DS role'           (Get-Val $adOut 'ADDS')       'Installed'
    Test-Val      'DNS Server role'      (Get-Val $adOut 'DNS_ROLE')   'Installed'

    # =========================================================================
    # 8. vm-app01 / vm-sql01: Domain Join
    # =========================================================================
    Write-Host "`n=== 8. vm-app01 / vm-sql01: Domain Join ===" -ForegroundColor Cyan
    Write-Host "  Running remote commands (PowerShell Direct)..." -ForegroundColor Gray

    $djOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
foreach ($vm in @('vm-app01','vm-sql01')) {
    try {
        $r = Invoke-Command -VMName $vm -Credential $cred -ScriptBlock {
            $cs = Get-WmiObject Win32_ComputerSystem
            Write-Output ('PART_OF_DOMAIN=' + $cs.PartOfDomain)
            Write-Output ('DOMAIN=' + $cs.Domain)
        } -ErrorAction Stop
        foreach ($line in ($r -split "`n")) {
            if ($line -match '^(PART_OF_DOMAIN|DOMAIN)=') { Write-Output ($vm + '_' + $line.Trim()) }
        }
    } catch {
        Write-Output ($vm + '_PART_OF_DOMAIN=ERROR')
        Write-Output ($vm + '_DOMAIN=ERROR')
    }
}
'@

    foreach ($vm in @('vm-app01', 'vm-sql01')) {
        Test-Val "$vm domain joined" (Get-Val $djOut "${vm}_PART_OF_DOMAIN") 'True'
        $djDomain = Get-Val $djOut "${vm}_DOMAIN"
        Write-Host "         Domain: $djDomain" -ForegroundColor Gray
    }

    # =========================================================================
    # 9. Internal Connectivity (from vm-app01)
    # =========================================================================
    Write-Host "`n=== 9. Internal Connectivity (from vm-app01) ===" -ForegroundColor Cyan
    Write-Host "  Running remote commands (PowerShell Direct)..." -ForegroundColor Gray

    $connOut = Invoke-HostCommand @'
$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)
try {
    $r = Invoke-Command -VMName 'vm-app01' -Credential $cred -ScriptBlock {
        $d = Test-NetConnection -ComputerName '192.168.100.10' -Port 3389 -WarningAction SilentlyContinue
        Write-Output ('AD_RDP=' + $d.TcpTestSucceeded)
        $s = Test-NetConnection -ComputerName '192.168.100.12' -Port 3389 -WarningAction SilentlyContinue
        Write-Output ('SQL_RDP=' + $s.TcpTestSucceeded)
        $dns = Resolve-DnsName 'contoso.local' -ErrorAction SilentlyContinue
        Write-Output ('DNS_RESOLVE=' + $(if ($dns) { $dns[0].IPAddress } else { '' }))
        $gw = Test-NetConnection -ComputerName '192.168.100.1' -WarningAction SilentlyContinue
        Write-Output ('GW_PING=' + $gw.PingSucceeded)
    } -ErrorAction Stop
    $r | ForEach-Object { Write-Output $_ }
} catch {
    Write-Output "AD_RDP=ERROR: $($_.Exception.Message)"
}
'@

    Test-Val     'vm-app01 -> vm-ad01:3389'   (Get-Val $connOut 'AD_RDP')      'True'
    Test-Val     'vm-app01 -> vm-sql01:3389'  (Get-Val $connOut 'SQL_RDP')     'True'
    Test-NotEmpty 'DNS resolve contoso.local'  (Get-Val $connOut 'DNS_RESOLVE')
    Test-Val     'vm-app01 -> Gateway ping'   (Get-Val $connOut 'GW_PING')     'True'
}

# =============================================================================
# Summary
# =============================================================================
$color = if ($passed -eq $total) { 'Green' } else { 'Yellow' }
Write-Host ("`n=== Result: {0} / {1} passed ===" -f $passed, $total) -ForegroundColor $color
if ($passed -lt $total) {
    Write-Host "  Review [FAIL] items above." -ForegroundColor Yellow
}
