# =============================================================================
# Setup-NestedEnvironment.ps1
# Run on Hyper-V host VM (NOT from remote PC):
#   All-in-one script to set up the nested on-prem environment.
#
# Phases:
#   1. Network setup (Internal NAT switch + DHCP)
#   2. Detect uploaded disks, convert to VHDX, inject unattend.xml, create VMs
#   3. Start VMs + wait for OOBE completion
#   4. Configure static IPs + hostname rename + reboot wait
#   5. Install AD DS + promote to Domain Controller + reboot wait
#   6. Domain join (vm-app01, vm-sql01) + reboot wait
#   7. Cleanup (delete unattend.xml) + optional password change
#   8. Final verification
#
# Features:
#   - Idempotent: safe to re-run (each phase skips if already done)
#   - Progress log: writes phase completion to a log file on host
#   - Resume: use -StartFromPhase to skip completed phases
#   - Optional password change: use -NewPassword to change all passwords
#
# Prerequisites:
#   - Upload-VHDs.ps1 has attached WS2022 (LUN 1) / WS2019 (LUN 2)
#   - Hyper-V role is installed (auto-installed during deployment)
#
# Usage:
#   .\Setup-NestedEnvironment.ps1
#   .\Setup-NestedEnvironment.ps1 -StartFromPhase 5
#   .\Setup-NestedEnvironment.ps1 -NewPassword 'MyN3wP@ss!'
#   .\Setup-NestedEnvironment.ps1 -Force              # skip confirmation
#   .\Setup-NestedEnvironment.ps1 -StartFromPhase 5 -Force
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateRange(1, 8)]
    [int]$StartFromPhase = 1,

    [string]$NewPassword,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# Configuration (edit here only)
# =============================================================================
$cfg = @{
    # --- Credentials ---
    SetupPassword    = 'P@ssW0rd1234!'

    # --- Domain ---
    DomainName       = 'contoso.local'
    DomainNetBIOS    = 'CONTOSO'

    # --- Network ---
    SwitchName       = 'InternalNAT'
    NatName          = 'NestedVMNAT'
    GatewayIP        = '192.168.100.1'
    PrefixLength     = 24
    NatPrefix        = '192.168.100.0/24'
    DhcpScopeStart   = '192.168.100.100'
    DhcpScopeEnd     = '192.168.100.200'
    DhcpSubnetMask   = '255.255.255.0'

    # --- Paths ---
    VhdxPath         = 'F:\Hyper-V\Virtual Hard Disks'
    VmPath           = 'F:\Hyper-V\Virtual Machines'
    LogFile          = 'F:\Hyper-V\setup-progress.log'

    # --- OS images (LUN mapping for uploaded VHDs) ---
    # Upload-VHDs.ps1 attaches VHDs as Managed Disks at these LUNs.
    # Add/remove entries to match the VHDs you upload.
    # Supported: ws2019, ws2022, ws2025
    OSImages         = @{
        'ws2022' = @{ Lun = 1; Label = 'Windows Server 2022' }
        'ws2019' = @{ Lun = 2; Label = 'Windows Server 2019' }
        # 'ws2025' = @{ Lun = 3; Label = 'Windows Server 2025' }
    }

    # --- Timing (seconds) ---
    Timing           = @{
        # Polling intervals
        VmPollIntervalSec            = 5     # Wait-ForVM polling cycle
        DcReadyPollIntervalSec       = 10    # AD DS readiness check cycle

        # Timeouts
        DefaultVmTimeoutSec          = 300   # Wait-ForVM default (5 min)
        OobeTimeoutSec               = 600   # Phase 3: first boot OOBE (10 min)
        RenameRebootTimeoutSec       = 120   # Phase 4: hostname rename reboot (2 min)
        DcReadyTimeoutSec            = 240   # Phase 5: DC promotion readiness (4 min)
        DomainJoinRebootTimeoutSec   = 180   # Phase 6: domain join reboot (3 min)

        # Reboot guards (fixed sleep before polling to avoid connecting to pre-reboot session)
        RenameRebootGuardSec         = 10    # Phase 4: wait for restart to begin
        DcPromotionRebootGuardSec    = 30    # Phase 5: DC reboot takes longer to initiate
        DomainJoinRebootGuardSec     = 15    # Phase 6: wait for restart to begin
    }
}

# --- Nested VM definitions ---
# OSVersion must match a key in $cfg.OSImages above
$nestedVMs = @(
    @{
        Name           = 'vm-ad01'
        Description    = 'Active Directory Domain Controller'
        OSVersion      = 'ws2022'       # ws2019 | ws2022 | ws2025
        MemoryBytes    = 4GB
        ProcessorCount = 2
        IP             = '192.168.100.10'
        DNS            = '127.0.0.1'
    }
    @{
        Name           = 'vm-app01'
        Description    = 'Application Server'
        OSVersion      = 'ws2019'       # ws2019 | ws2022 | ws2025
        MemoryBytes    = 4GB
        ProcessorCount = 2
        IP             = '192.168.100.11'
        DNS            = '192.168.100.10'
    }
    @{
        Name           = 'vm-sql01'
        Description    = 'SQL Server'
        OSVersion      = 'ws2019'       # ws2019 | ws2022 | ws2025
        MemoryBytes    = 8GB
        ProcessorCount = 2
        IP             = '192.168.100.12'
        DNS            = '192.168.100.10'
    }
)

# --- Validate OSVersion references ---
foreach ($vm in $nestedVMs) {
    if (-not $cfg.OSImages.ContainsKey($vm.OSVersion)) {
        throw "VM '$($vm.Name)' references OSVersion '$($vm.OSVersion)' which is not defined in `$cfg.OSImages. Available: $($cfg.OSImages.Keys -join ', ')"
    }
}

# =============================================================================
# Pre-execution summary + confirmation
# =============================================================================
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host '  Setup-NestedEnvironment' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host ''
Write-Host "  Domain:       $($cfg.DomainName) ($($cfg.DomainNetBIOS))"
Write-Host "  Password:     $($cfg.SetupPassword)"
Write-Host "  Network:      $($cfg.NatPrefix) (GW: $($cfg.GatewayIP))"
if ($NewPassword) {
    Write-Host "  New Password: $NewPassword (will be changed in Phase 7)" -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  VMs:'
foreach ($vm in $nestedVMs) {
    $osLabel = $cfg.OSImages[$vm.OSVersion].Label
    Write-Host "    $($vm.Name.PadRight(12)) $($vm.OSVersion)  $($vm.IP.PadRight(16)) $($vm.Description)"
}
Write-Host ''
Write-Host "  Phases to execute: $StartFromPhase -> 8"
Write-Host ''

if (-not $Force) {
    $answer = Read-Host '  続行しますか? (y/N)'
    if ($answer -ne 'y') {
        Write-Host '  中断しました。' -ForegroundColor Yellow
        exit 0
    }
    Write-Host ''
}

# --- Unattend.xml template ---
$unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$($cfg.SetupPassword)</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@

# =============================================================================
# Helper functions
# =============================================================================

function Write-Phase ([int]$Phase, [string]$Title) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  Phase $Phase : $Title" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

function Write-Log ([string]$Message) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    Write-Host "  $line"
    Add-Content -Path $cfg.LogFile -Value $line -Encoding UTF8
}

function Complete-Phase ([int]$Phase, [string]$Title) {
    Write-Log "Phase $Phase completed: $Title"
    Write-Host "  Phase $Phase completed." -ForegroundColor Green
}

function Get-LocalCred {
    $secPwd = ConvertTo-SecureString $cfg.SetupPassword -AsPlainText -Force
    [System.Management.Automation.PSCredential]::new('.\Administrator', $secPwd)
}

function Get-DomainCred {
    $secPwd = ConvertTo-SecureString $cfg.SetupPassword -AsPlainText -Force
    [System.Management.Automation.PSCredential]::new("$($cfg.DomainNetBIOS)\Administrator", $secPwd)
}

function Wait-ForVM (
    [string]$VMName,
    [pscredential]$Credential,
    [int]$TimeoutSeconds  = $cfg.Timing.DefaultVmTimeoutSec,
    [int]$PollIntervalSec = $cfg.Timing.VmPollIntervalSec
) {
    Write-Host "  Waiting for $VMName to respond..." -NoNewline
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            Invoke-Command -VMName $VMName -Credential $Credential `
                -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop | Out-Null
            Write-Host ' OK' -ForegroundColor Green
            return $true
        } catch {
            Write-Host '.' -NoNewline
            Start-Sleep -Seconds $PollIntervalSec
            $elapsed += $PollIntervalSec
        }
    }
    Write-Host ' TIMEOUT' -ForegroundColor Red
    return $false
}

# =============================================================================
# Phase 1: Network setup (NAT + DHCP)
# =============================================================================
if ($StartFromPhase -le 1) {
    Write-Phase 1 'Network setup (NAT + DHCP)'

    # Create Internal VM Switch
    Write-Host '  [1/4] Creating Internal VM Switch...'
    if (-not (Get-VMSwitch -Name $cfg.SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $cfg.SwitchName -SwitchType Internal
        Write-Host '    Created.'
    } else {
        Write-Host '    Already exists. Skipping.'
    }

    # Assign gateway IP
    Write-Host "  [2/4] Assigning gateway IP: $($cfg.GatewayIP)"
    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$($cfg.SwitchName)*" }
    $existingIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $cfg.GatewayIP }
    if (-not $existingIP) {
        New-NetIPAddress -IPAddress $cfg.GatewayIP -PrefixLength $cfg.PrefixLength -InterfaceIndex $adapter.ifIndex
        Write-Host '    Assigned.'
    } else {
        Write-Host '    Already assigned. Skipping.'
    }

    # Create NAT
    Write-Host "  [3/4] Creating NAT: $($cfg.NatName)"
    if (-not (Get-NetNat -Name $cfg.NatName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $cfg.NatName -InternalIPInterfaceAddressPrefix $cfg.NatPrefix
        Write-Host '    Created.'
    } else {
        Write-Host '    Already exists. Skipping.'
    }

    # DHCP scope
    Write-Host '  [4/4] Configuring DHCP scope...'
    $scopeExists = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
        Where-Object { $_.StartRange -eq $cfg.DhcpScopeStart }
    if (-not $scopeExists) {
        Add-DhcpServerv4Scope -Name 'NestedVMs' `
            -StartRange $cfg.DhcpScopeStart `
            -EndRange $cfg.DhcpScopeEnd `
            -SubnetMask $cfg.DhcpSubnetMask `
            -State Active
        Set-DhcpServerv4OptionValue -Router $cfg.GatewayIP
        Write-Host '    Configured.'
    } else {
        Write-Host '    Already exists. Skipping.'
    }

    Complete-Phase 1 'Network setup'
}

# =============================================================================
# Phase 2: Convert VHD -> VHDX, inject unattend.xml, create VMs
# =============================================================================
if ($StartFromPhase -le 2) {
    Write-Phase 2 'Disk conversion + VM creation'

    # --- Detect uploaded disks ---
    # Upload-VHDs.ps1 が VHD を Azure Managed Disk としてアップロードし、
    # ホスト VM に LUN 番号を指定してアタッチしている。
    # ホスト VM 内ではファイル名は見えないため、$cfg.OSImages の LUN 定義と
    # Get-Disk の結果を照合して OS バージョンとディスクを対応付ける。
    #   LUN 1 -> ws2022, LUN 2 -> ws2019, LUN 3 -> ws2025 (例)
    Write-Host '  Detecting uploaded disks...'
    Update-HostStorageCache

    $fPartition = Get-Partition -DriveLetter F -ErrorAction SilentlyContinue
    if (-not $fPartition) { throw 'F: drive not found. Verify data disk.' }
    $dataDiskNumber = $fPartition.DiskNumber

    # OS Disk (0) と Data Disk (F:) を除いた残りがアップロード済み VHD ディスク
    $uploadDisks = Get-Disk | Where-Object {
        $_.Number -ne 0 -and $_.Number -ne $dataDiskNumber
    } | Sort-Object Number

    # VM 定義で使われている OS バージョンのみ検索対象にする
    $requiredOSVersions = $nestedVMs.OSVersion | Sort-Object -Unique
    $expectedDiskCount = ($requiredOSVersions | ForEach-Object { $cfg.OSImages[$_].Lun } | Sort-Object -Unique).Count

    if ($uploadDisks.Count -lt $expectedDiskCount) {
        throw "Expected $expectedDiskCount upload disk(s) for OS versions [$($requiredOSVersions -join ', ')] but found $($uploadDisks.Count). Run Upload-VHDs.ps1 first."
    }

    # LUN 順にソートし、OS バージョン -> 物理ディスクのマッピングを構築
    $sortedLuns = $cfg.OSImages.GetEnumerator() |
        Where-Object { $_.Key -in $requiredOSVersions } |
        Sort-Object { $_.Value.Lun }

    $diskByOS = @{}
    foreach ($entry in $sortedLuns) {
        $lunIndex = $entry.Value.Lun - 1  # LUN 1 -> index 0
        if ($lunIndex -ge $uploadDisks.Count) {
            throw "Disk for $($entry.Value.Label) (LUN $($entry.Value.Lun)) not found."
        }
        $diskByOS[$entry.Key] = $uploadDisks[$lunIndex]
        Write-Host "    $($entry.Value.Label): Disk $($uploadDisks[$lunIndex].Number) ($([math]::Round($uploadDisks[$lunIndex].Size/1GB,1)) GB) [LUN $($entry.Value.Lun)]"
    }

    $generationMap = @{}
    foreach ($d in $uploadDisks) {
        $generationMap[$d.Number] = if ($d.PartitionStyle -eq 'GPT') { 2 } else { 1 }
    }

    # --- Set disks offline ---
    foreach ($d in $uploadDisks) {
        if ($d.OperationalStatus -ne 'Offline') {
            Write-Host "    Setting Disk $($d.Number) offline..."
            Set-Disk -Number $d.Number -IsOffline $true
        }
    }

    # --- Convert to VHDX base images ---
    # LUN で特定したディスクを New-VHD -SourceDisk で VHDX に変換する。
    # ディスクはオフラインにしておく必要がある (SourceDisk はディスク番号を指定)。
    Write-Host '  Converting to VHDX base images...'
    New-Item -Path $cfg.VhdxPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    $baseImages = @{}
    foreach ($os in $diskByOS.Keys) {
        $baseImages[$os] = @{
            Path       = "$($cfg.VhdxPath)\$os-base.vhdx"
            DiskNumber = $diskByOS[$os].Number
        }
    }

    foreach ($os in $baseImages.Keys) {
        $img = $baseImages[$os]
        if (Test-Path $img.Path) {
            Write-Host "    $os base already exists. Skipping."
        } else {
            Write-Host "    $os -> VHDX (Disk $($img.DiskNumber))... (may take a few minutes)"
            New-VHD -Path $img.Path -SourceDisk $img.DiskNumber -Dynamic
            Write-Host "    Done: $($img.Path)"
        }
    }

    # --- Copy VHDX per VM ---
    Write-Host '  Copying VHDX per VM...'
    foreach ($vmConfig in $nestedVMs) {
        $vmVhdx = "$($cfg.VhdxPath)\$($vmConfig.Name).vhdx"
        $baseVhdx = $baseImages[$vmConfig.OSVersion].Path
        if (Test-Path $vmVhdx) {
            Write-Host "    $($vmConfig.Name).vhdx already exists. Skipping."
        } else {
            Write-Host "    Copying -> $($vmConfig.Name).vhdx..."
            Copy-Item -Path $baseVhdx -Destination $vmVhdx
        }
    }

    # --- Inject unattend.xml ---
    Write-Host '  Injecting unattend.xml...'
    foreach ($vmConfig in $nestedVMs) {
        $vmVhdx = "$($cfg.VhdxPath)\$($vmConfig.Name).vhdx"

        # Skip if VM already exists (unattend already consumed)
        if (Get-VM -Name $vmConfig.Name -ErrorAction SilentlyContinue) {
            Write-Host "    $($vmConfig.Name): VM exists, skipping injection."
            continue
        }

        Mount-VHD -Path $vmVhdx
        try {
            $mountedDisk = Get-VHD -Path $vmVhdx
            $diskNumber = $mountedDisk.DiskNumber

            $partition = Get-Partition -DiskNumber $diskNumber |
                Where-Object { $_.Type -ne 'System' -and $_.Type -ne 'Reserved' -and $_.DriveLetter } |
                Sort-Object Size -Descending | Select-Object -First 1

            if (-not $partition -or -not $partition.DriveLetter) {
                $partition = Get-Partition -DiskNumber $diskNumber |
                    Where-Object { $_.Type -ne 'System' -and $_.Type -ne 'Reserved' } |
                    Sort-Object Size -Descending | Select-Object -First 1
                if ($partition) {
                    $partition | Add-PartitionAccessPath -AssignDriveLetter
                    $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber
                }
            }

            if (-not $partition -or -not $partition.DriveLetter) {
                Write-Host "    $($vmConfig.Name): ERROR - no drive letter. Skipping." -ForegroundColor Red
                continue
            }

            $driveLetter = $partition.DriveLetter
            if (-not (Test-Path "${driveLetter}:\Windows")) {
                Write-Host "    $($vmConfig.Name): ERROR - not a Windows partition. Skipping." -ForegroundColor Red
                continue
            }

            $pantherPath = "${driveLetter}:\Windows\Panther"
            if (-not (Test-Path $pantherPath)) {
                New-Item -Path $pantherPath -ItemType Directory -Force | Out-Null
            }

            $unattendXml | Out-File -FilePath "$pantherPath\unattend.xml" -Encoding utf8 -Force
            Write-Host "    $($vmConfig.Name): injected unattend.xml" -ForegroundColor Green
        } finally {
            Dismount-VHD -Path $vmVhdx
        }
    }

    # --- Create VMs ---
    Write-Host '  Creating VMs...'
    if (-not (Get-VMSwitch -Name $cfg.SwitchName -ErrorAction SilentlyContinue)) {
        throw "VM switch '$($cfg.SwitchName)' not found."
    }
    New-Item -Path $cfg.VmPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    foreach ($vmConfig in $nestedVMs) {
        if (Get-VM -Name $vmConfig.Name -ErrorAction SilentlyContinue) {
            Write-Host "    $($vmConfig.Name) already exists. Skipping."
            continue
        }

        $vmVhdx = "$($cfg.VhdxPath)\$($vmConfig.Name).vhdx"
        $sourceDiskNumber = $baseImages[$vmConfig.OSVersion].DiskNumber
        $generation = $generationMap[$sourceDiskNumber]

        Write-Host "    Creating $($vmConfig.Name) (Gen$generation, $($vmConfig.MemoryBytes/1GB)GB, $($vmConfig.ProcessorCount)vCPU)..."

        New-VM -Name $vmConfig.Name -Path $cfg.VmPath -Generation $generation `
            -MemoryStartupBytes $vmConfig.MemoryBytes -VHDPath $vmVhdx -SwitchName $cfg.SwitchName | Out-Null
        Set-VM -Name $vmConfig.Name -ProcessorCount $vmConfig.ProcessorCount -StaticMemory -CheckpointType Disabled

        if ($generation -eq 2) {
            Set-VMFirmware -VMName $vmConfig.Name -SecureBootTemplate MicrosoftWindows
        }

        Write-Host "    $($vmConfig.Name) created." -ForegroundColor Green
    }

    Complete-Phase 2 'Disk conversion + VM creation'
}

# =============================================================================
# Phase 3: Start VMs + wait for OOBE completion
# =============================================================================
if ($StartFromPhase -le 3) {
    Write-Phase 3 'Start VMs + wait for OOBE'

    $localCred = Get-LocalCred

    foreach ($vmConfig in $nestedVMs) {
        $vm = Get-VM -Name $vmConfig.Name
        if ($vm.State -ne 'Running') {
            Write-Host "  Starting $($vmConfig.Name)..."
            Start-VM -Name $vmConfig.Name
        } else {
            Write-Host "  $($vmConfig.Name) already running."
        }
    }

    Write-Host '  Waiting for OOBE to complete on all VMs (this may take 2-5 minutes)...'
    foreach ($vmConfig in $nestedVMs) {
        if (-not (Wait-ForVM -VMName $vmConfig.Name -Credential $localCred -TimeoutSeconds $cfg.Timing.OobeTimeoutSec)) {
            throw "$($vmConfig.Name) did not respond within $($cfg.Timing.OobeTimeoutSec)s. Check OOBE status via Hyper-V Manager."
        }
    }

    Complete-Phase 3 'VMs started, OOBE complete'
}

# =============================================================================
# Phase 4: Configure static IPs + hostname rename
# =============================================================================
if ($StartFromPhase -le 4) {
    Write-Phase 4 'Static IPs + hostname'

    $localCred = Get-LocalCred

    foreach ($vmConfig in $nestedVMs) {
        Write-Host "  Configuring $($vmConfig.Name): $($vmConfig.IP)..."

        Invoke-Command -VMName $vmConfig.Name -Credential $localCred -ScriptBlock {
            param($IP, $DNS, $DesiredName, $Gateway)

            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
            $ifAlias = $adapter.Name

            # Remove existing IP config
            Remove-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceAlias $ifAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

            # Set static IP
            New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $IP -PrefixLength 24 -DefaultGateway $Gateway
            Set-DnsClientServerAddress -InterfaceAlias $ifAlias -ServerAddresses $DNS
            Set-NetIPInterface -InterfaceAlias $ifAlias -Dhcp Disabled -ErrorAction SilentlyContinue

            # Enable ICMP + RDP
            Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
            Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue

            # Rename if needed
            if ($env:COMPUTERNAME -ne $DesiredName) {
                Rename-Computer -NewName $DesiredName -Force
                Write-Host "    Renamed: $env:COMPUTERNAME -> $DesiredName"
            }
        } -ArgumentList $vmConfig.IP, $vmConfig.DNS, $vmConfig.Name, $cfg.GatewayIP
    }

    # Enable ICMP on host
    Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue

    # Verify connectivity
    foreach ($vmConfig in $nestedVMs) {
        $ping = Test-Connection -ComputerName $vmConfig.IP -Count 1 -Quiet
        Write-Host "  Ping $($vmConfig.Name) ($($vmConfig.IP)): $(if ($ping) { 'OK' } else { 'FAIL' })"
    }

    # Restart VMs for hostname changes
    Write-Host '  Checking hostname changes...'
    $needsRestart = $false
    foreach ($vmConfig in $nestedVMs) {
        $actualName = Invoke-Command -VMName $vmConfig.Name -Credential $localCred -ScriptBlock { $env:COMPUTERNAME }
        if ($actualName -ne $vmConfig.Name) {
            Write-Host "    $($vmConfig.Name): restarting for rename ($actualName -> $($vmConfig.Name))..."
            Restart-VM -Name $vmConfig.Name -Force
            $needsRestart = $true
        } else {
            Write-Host "    $($vmConfig.Name): hostname OK"
        }
    }

    if ($needsRestart) {
        Write-Host '  Waiting for VMs to restart...'
        Start-Sleep -Seconds $cfg.Timing.RenameRebootGuardSec
        foreach ($vmConfig in $nestedVMs) {
            if (-not (Wait-ForVM -VMName $vmConfig.Name -Credential $localCred -TimeoutSeconds $cfg.Timing.RenameRebootTimeoutSec)) {
                Write-Host "    $($vmConfig.Name): not responding after restart" -ForegroundColor Yellow
            }
        }
    }

    Complete-Phase 4 'Static IPs + hostname'
}

# =============================================================================
# Phase 5: Install AD DS + promote DC
# =============================================================================
if ($StartFromPhase -le 5) {
    Write-Phase 5 'AD DS installation + DC promotion'

    $localCred = Get-LocalCred
    $dcVM = 'vm-ad01'

    # Pre-check hostname
    $actualHostname = Invoke-Command -VMName $dcVM -Credential $localCred -ScriptBlock { $env:COMPUTERNAME }
    if ($actualHostname -ne $dcVM) {
        throw "$dcVM hostname is '$actualHostname', expected '$dcVM'. Re-run from Phase 4."
    }
    Write-Host "  Hostname: $actualHostname (OK)"

    # Check if already a DC
    $domainCred = Get-DomainCred
    $alreadyDC = $false
    try {
        Invoke-Command -VMName $dcVM -Credential $domainCred -ScriptBlock {
            (Get-ADDomainController -ErrorAction Stop).HostName
        } -ErrorAction Stop | Out-Null
        $alreadyDC = $true
        Write-Host '  Already a Domain Controller. Skipping promotion.'
    } catch {
        # Not a DC yet, proceed
    }

    if (-not $alreadyDC) {
        # Install AD DS role
        Write-Host '  Installing AD DS role...'
        Invoke-Command -VMName $dcVM -Credential $localCred -ScriptBlock {
            if (-not (Get-WindowsFeature AD-Domain-Services).Installed) {
                Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
                Write-Host '    AD DS role installed.'
            } else {
                Write-Host '    AD DS role already installed.'
            }
        }

        # Promote to DC (this will reboot vm-ad01 and kill the session)
        Write-Host '  Promoting to Domain Controller...'
        Write-Host '    (vm-ad01 will reboot — connection drop is expected)'
        $secPwd = ConvertTo-SecureString $cfg.SetupPassword -AsPlainText -Force
        try {
            Invoke-Command -VMName $dcVM -Credential $localCred -ScriptBlock {
                param($DomainName, $NetBIOSName, $SafeModePwd)
                Import-Module ADDSDeployment
                Install-ADDSForest `
                    -DomainName $DomainName `
                    -DomainNetbiosName $NetBIOSName `
                    -SafeModeAdministratorPassword $SafeModePwd `
                    -InstallDns:$true `
                    -NoRebootOnCompletion:$false `
                    -Force:$true
            } -ArgumentList $cfg.DomainName, $cfg.DomainNetBIOS, $secPwd
        } catch {
            # Expected: session disconnects during reboot
            Write-Host '    Session disconnected (expected during DC reboot).'
        }

        # Wait for DC to come back as domain controller
        Write-Host '  Waiting for DC to restart and become available...'
        Start-Sleep -Seconds $cfg.Timing.DcPromotionRebootGuardSec
        $dcReady = $false
        $retries = 0
        $pollSec = $cfg.Timing.DcReadyPollIntervalSec
        $maxRetries = [math]::Floor($cfg.Timing.DcReadyTimeoutSec / $pollSec)

        while (-not $dcReady -and $retries -lt $maxRetries) {
            try {
                $result = Invoke-Command -VMName $dcVM -Credential $domainCred -ScriptBlock {
                    (Get-ADDomainController -ErrorAction Stop).HostName
                } -ErrorAction Stop
                Write-Host "  DC is ready: $result" -ForegroundColor Green
                $dcReady = $true
            } catch {
                $retries++
                Write-Host "    Not ready yet (attempt $retries/$maxRetries)..." -NoNewline
                Start-Sleep -Seconds $pollSec
                Write-Host ''
            }
        }

        if (-not $dcReady) {
            throw "DC did not become ready after $($cfg.Timing.DcReadyTimeoutSec)s ($maxRetries attempts)."
        }
    }

    Complete-Phase 5 'AD DS + DC promotion'
}

# =============================================================================
# Phase 6: Domain join (vm-app01, vm-sql01)
# =============================================================================
if ($StartFromPhase -le 6) {
    Write-Phase 6 'Domain join'

    $localCred = Get-LocalCred
    $domainCred = Get-DomainCred

    # Update DHCP DNS to point to DC
    Write-Host "  Updating DHCP DNS -> $($nestedVMs[0].IP)"
    Set-DhcpServerv4OptionValue -DnsServer $nestedVMs[0].IP

    # Join each non-DC VM
    $joinVMs = $nestedVMs | Where-Object { $_.Name -ne 'vm-ad01' }

    foreach ($vmConfig in $joinVMs) {
        # Check if already domain-joined
        $alreadyJoined = $false
        try {
            $partOfDomain = Invoke-Command -VMName $vmConfig.Name -Credential $domainCred -ScriptBlock {
                (Get-WmiObject Win32_ComputerSystem).PartOfDomain
            } -ErrorAction Stop
            if ($partOfDomain) { $alreadyJoined = $true }
        } catch {
            # Cannot connect with domain cred -> not joined yet
        }

        if ($alreadyJoined) {
            Write-Host "  $($vmConfig.Name): already domain-joined. Skipping."
            continue
        }

        Write-Host "  Joining $($vmConfig.Name) to $($cfg.DomainName)..."
        try {
            Invoke-Command -VMName $vmConfig.Name -Credential $localCred -ScriptBlock {
                param($Domain, $DomCred)
                $dns = Resolve-DnsName $Domain -ErrorAction SilentlyContinue
                if ($dns) {
                    Write-Host "    DNS resolution OK: $($dns[0].IPAddress)"
                }
                Add-Computer -DomainName $Domain -Credential $DomCred -Restart -Force
            } -ArgumentList $cfg.DomainName, $domainCred
        } catch {
            # Session may drop during restart
            Write-Host "    Session disconnected (expected during reboot)."
        }
    }

    # Wait for joined VMs to come back
    Write-Host '  Waiting for VMs to restart after domain join...'
    Start-Sleep -Seconds $cfg.Timing.DomainJoinRebootGuardSec
    foreach ($vmConfig in $joinVMs) {
        if (-not (Wait-ForVM -VMName $vmConfig.Name -Credential $domainCred -TimeoutSeconds $cfg.Timing.DomainJoinRebootTimeoutSec)) {
            Write-Host "    $($vmConfig.Name): not responding after domain join" -ForegroundColor Yellow
        }
    }

    Complete-Phase 6 'Domain join'
}

# =============================================================================
# Phase 7: Cleanup (unattend.xml deletion + optional password change)
# =============================================================================
if ($StartFromPhase -le 7) {
    Write-Phase 7 'Cleanup'

    $domainCred = Get-DomainCred
    $localCred = Get-LocalCred

    # --- Delete unattend.xml from all VMs ---
    Write-Host '  Removing unattend.xml from all VMs...'
    foreach ($vmConfig in $nestedVMs) {
        $cred = if ($vmConfig.Name -eq 'vm-ad01') { $domainCred } else { $domainCred }
        try {
            $removed = Invoke-Command -VMName $vmConfig.Name -Credential $cred -ScriptBlock {
                $paths = @(
                    'C:\Windows\Panther\unattend.xml',
                    'C:\Windows\System32\Sysprep\unattend.xml'
                )
                $found = $false
                foreach ($p in $paths) {
                    if (Test-Path $p) {
                        Remove-Item $p -Force
                        $found = $true
                    }
                }
                $found
            } -ErrorAction Stop
            if ($removed) {
                Write-Host "    $($vmConfig.Name): unattend.xml deleted" -ForegroundColor Green
            } else {
                Write-Host "    $($vmConfig.Name): unattend.xml not found (already clean)"
            }
        } catch {
            Write-Host "    $($vmConfig.Name): WARNING - could not remove unattend.xml ($_)" -ForegroundColor Yellow
        }
    }

    # --- Optional password change ---
    if ($NewPassword) {
        Write-Host ''
        Write-Host '  Changing passwords on all VMs...'
        $newSecPwd = ConvertTo-SecureString $NewPassword -AsPlainText -Force

        # Change domain Administrator password on DC
        Write-Host '    Changing domain Administrator password...'
        Invoke-Command -VMName 'vm-ad01' -Credential $domainCred -ScriptBlock {
            param($NewPwd)
            Set-ADAccountPassword -Identity 'Administrator' `
                -NewPassword $NewPwd -Reset
        } -ArgumentList $newSecPwd

        # Update credential for subsequent commands
        $newDomainCred = [System.Management.Automation.PSCredential]::new(
            "$($cfg.DomainNetBIOS)\Administrator", $newSecPwd)

        # Change local Administrator password on each VM
        foreach ($vmConfig in $nestedVMs) {
            Write-Host "    $($vmConfig.Name): changing local Administrator password..."
            try {
                $cred = if ($vmConfig.Name -eq 'vm-ad01') { $newDomainCred } else { $newDomainCred }
                Invoke-Command -VMName $vmConfig.Name -Credential $cred -ScriptBlock {
                    param($NewPwd)
                    Set-LocalUser -Name 'Administrator' -Password $NewPwd
                } -ArgumentList $newSecPwd
            } catch {
                Write-Host "      WARNING: $($vmConfig.Name) local password change failed ($_)" -ForegroundColor Yellow
            }
        }

        Write-Host ''
        Write-Host '  ================================================' -ForegroundColor Yellow
        Write-Host "  Password changed to: $NewPassword" -ForegroundColor Yellow
        Write-Host '  This is displayed only once. Save it now.' -ForegroundColor Yellow
        Write-Host '  ================================================' -ForegroundColor Yellow
    }

    Complete-Phase 7 'Cleanup'
}

# =============================================================================
# Phase 8: Final verification
# =============================================================================
if ($StartFromPhase -le 8) {
    Write-Phase 8 'Final verification'

    $cred = if ($NewPassword) {
        $sec = ConvertTo-SecureString $NewPassword -AsPlainText -Force
        [System.Management.Automation.PSCredential]::new("$($cfg.DomainNetBIOS)\Administrator", $sec)
    } else {
        Get-DomainCred
    }

    $allPassed = $true

    # Test 1: Ping all VMs
    Write-Host '  [1/4] Network connectivity...'
    foreach ($vmConfig in $nestedVMs) {
        $ping = Test-Connection -ComputerName $vmConfig.IP -Count 1 -Quiet
        $status = if ($ping) { 'PASS' } else { 'FAIL'; $allPassed = $false }
        $color = if ($ping) { 'Green' } else { 'Red' }
        Write-Host "    [$status] Ping $($vmConfig.Name) ($($vmConfig.IP))" -ForegroundColor $color
    }

    # Test 2: Hostname matches
    Write-Host '  [2/4] Hostname verification...'
    foreach ($vmConfig in $nestedVMs) {
        try {
            $name = Invoke-Command -VMName $vmConfig.Name -Credential $cred `
                -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            $ok = $name -eq $vmConfig.Name
            $status = if ($ok) { 'PASS' } else { 'FAIL'; $allPassed = $false }
            $color = if ($ok) { 'Green' } else { 'Red' }
            Write-Host "    [$status] $($vmConfig.Name): $name" -ForegroundColor $color
        } catch {
            Write-Host "    [FAIL] $($vmConfig.Name): cannot connect" -ForegroundColor Red
            $allPassed = $false
        }
    }

    # Test 3: Domain controller
    Write-Host '  [3/4] Domain controller...'
    try {
        $dcHost = Invoke-Command -VMName 'vm-ad01' -Credential $cred -ScriptBlock {
            (Get-ADDomainController).HostName
        } -ErrorAction Stop
        Write-Host "    [PASS] DC: $dcHost" -ForegroundColor Green
    } catch {
        Write-Host '    [FAIL] DC not responding' -ForegroundColor Red
        $allPassed = $false
    }

    # Test 4: Domain membership
    Write-Host '  [4/4] Domain membership...'
    foreach ($vmConfig in ($nestedVMs | Where-Object { $_.Name -ne 'vm-ad01' })) {
        try {
            $domain = Invoke-Command -VMName $vmConfig.Name -Credential $cred -ScriptBlock {
                (Get-WmiObject Win32_ComputerSystem).Domain
            } -ErrorAction Stop
            $ok = $domain -eq $cfg.DomainName
            $status = if ($ok) { 'PASS' } else { 'FAIL'; $allPassed = $false }
            $color = if ($ok) { 'Green' } else { 'Red' }
            Write-Host "    [$status] $($vmConfig.Name): $domain" -ForegroundColor $color
        } catch {
            Write-Host "    [FAIL] $($vmConfig.Name): cannot verify" -ForegroundColor Red
            $allPassed = $false
        }
    }

    # Test 5: unattend.xml removed
    Write-Host '  [5/4] unattend.xml cleanup...'
    foreach ($vmConfig in $nestedVMs) {
        try {
            $exists = Invoke-Command -VMName $vmConfig.Name -Credential $cred -ScriptBlock {
                Test-Path 'C:\Windows\Panther\unattend.xml'
            } -ErrorAction Stop
            $ok = -not $exists
            $status = if ($ok) { 'PASS' } else { 'WARN' }
            $color = if ($ok) { 'Green' } else { 'Yellow' }
            Write-Host "    [$status] $($vmConfig.Name): $(if ($ok) { 'removed' } else { 'still exists' })" -ForegroundColor $color
        } catch {
            Write-Host "    [FAIL] $($vmConfig.Name): cannot check" -ForegroundColor Red
        }
    }

    Write-Host ''
    if ($allPassed) {
        Write-Host '  All checks passed!' -ForegroundColor Green
    } else {
        Write-Host '  Some checks failed. Review output above.' -ForegroundColor Yellow
    }

    Complete-Phase 8 'Final verification'
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Green
Write-Host '  Setup-NestedEnvironment.ps1 completed' -ForegroundColor Green
Write-Host ('=' * 60) -ForegroundColor Green
Write-Host ''
Write-Host "  Log file: $($cfg.LogFile)"
Write-Host ''
Write-Host '  VMs:'
Get-VM | Where-Object { $_.Name -in $nestedVMs.Name } |
    Format-Table Name, State, @{N='MemoryGB'; E={$_.MemoryStartup/1GB}}, ProcessorCount -AutoSize

# --- Cleanup reminder: uploaded managed disks are no longer needed ---
$usedLuns = $nestedVMs | ForEach-Object { $cfg.OSImages[$_.OSVersion].Lun } | Sort-Object -Unique
$diskNames = $usedLuns | ForEach-Object {
    $osKey = $cfg.OSImages.GetEnumerator() | Where-Object { $_.Value.Lun -eq $_ } | Select-Object -First 1
    "disk-upload-$($osKey.Key)"
}
Write-Host 'Cleanup upload disks (run from local PC):' -ForegroundColor Yellow
foreach ($dn in $diskNames) {
    Write-Host "  az vm disk detach -g rg-onprem-nested --vm-name vm-onprem-nested-hv01 -n $dn"
}
foreach ($dn in $diskNames) {
    Write-Host "  az disk delete -g rg-onprem-nested -n $dn --yes"
}
Write-Host ''
