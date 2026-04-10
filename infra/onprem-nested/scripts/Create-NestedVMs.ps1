# =============================================================================
# Create-NestedVMs.ps1
# Run on Hyper-V host VM:
#   Convert attached Managed Disks (uploaded VHDs) to VHDX and create
#   3 nested VMs: AD / App / SQL
#
# Prerequisites:
#   - Upload-VHDs.ps1 has attached WS2022 (LUN 1) / WS2019 (LUN 2)
#   - Setup-NestedNetwork.ps1 has configured InternalNAT switch
#   - Hyper-V role is installed (auto-installed during deployment)
# =============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# --- Configuration ---
$vhdxPath   = 'F:\Hyper-V\Virtual Hard Disks'
$vmPath     = 'F:\Hyper-V\Virtual Machines'
$switchName = 'InternalNAT'

$nestedVMs = @(
    @{
        Name           = 'vm-ad01'
        Description    = 'Active Directory Domain Controller'
        OSVersion      = 'ws2022'
        SourceLun      = 1
        MemoryBytes    = 4GB
        ProcessorCount = 2
    }
    @{
        Name           = 'vm-app01'
        Description    = 'Application Server'
        OSVersion      = 'ws2019'
        SourceLun      = 2
        MemoryBytes    = 4GB
        ProcessorCount = 2
    }
    @{
        Name           = 'vm-sql01'
        Description    = 'SQL Server'
        OSVersion      = 'ws2019'
        SourceLun      = 2
        MemoryBytes    = 8GB
        ProcessorCount = 2
    }
)

# ============================================================================
# Step 1: Detect uploaded disks
# ============================================================================
Write-Host "========================================="
Write-Host "Step 1: Detecting uploaded disks"
Write-Host "========================================="

# Rescan disks
Update-HostStorageCache

# Get disk number for F: drive (data disk = LUN 0)
$fPartition = Get-Partition -DriveLetter F -ErrorAction SilentlyContinue
if (-not $fPartition) {
    throw "F: drive not found. Verify that the data disk has been initialized."
}
$dataDiskNumber = $fPartition.DiskNumber

# Identify uploaded disks (exclude OS disk and data disk)
$uploadDisks = Get-Disk | Where-Object {
    $_.Number -ne 0 -and $_.Number -ne $dataDiskNumber
} | Sort-Object Number

Write-Host "Detected upload disks:"
$uploadDisks | Format-Table Number, @{N='SizeGB'; E={[math]::Round($_.Size/1GB,1)}}, PartitionStyle, OperationalStatus -AutoSize

if ($uploadDisks.Count -lt 2) {
    throw "Expected 2 upload disks but found $($uploadDisks.Count). Run Upload-VHDs.ps1 first."
}

$diskWs2022 = $uploadDisks[0]  # LUN 1 = Windows Server 2022
$diskWs2019 = $uploadDisks[1]  # LUN 2 = Windows Server 2019

Write-Host "  WS2022 disk: Disk $($diskWs2022.Number) ($([math]::Round($diskWs2022.Size/1GB,1)) GB)"
Write-Host "  WS2019 disk: Disk $($diskWs2019.Number) ($([math]::Round($diskWs2019.Size/1GB,1)) GB)"

# Determine VM generation from partition style
$generationMap = @{}
foreach ($d in $uploadDisks) {
    $gen = if ($d.PartitionStyle -eq 'GPT') { 2 } else { 1 }
    $generationMap[$d.Number] = $gen
}

# ============================================================================
# Step 2: Convert disks to VHDX base images
# ============================================================================
Write-Host ""
Write-Host "========================================="
Write-Host "Step 2: Converting disks to VHDX base images"
Write-Host "========================================="

# Set disks offline (required for New-VHD -SourceDisk)
foreach ($d in $uploadDisks) {
    if ($d.OperationalStatus -ne 'Offline') {
        Write-Host "  Setting Disk $($d.Number) offline..."
        Set-Disk -Number $d.Number -IsOffline $true
    }
}

$baseImages = @{
    'ws2022' = @{ Path = "$vhdxPath\ws2022-base.vhdx"; DiskNumber = $diskWs2022.Number }
    'ws2019' = @{ Path = "$vhdxPath\ws2019-base.vhdx"; DiskNumber = $diskWs2019.Number }
}

foreach ($os in $baseImages.Keys) {
    $img = $baseImages[$os]
    if (Test-Path $img.Path) {
        Write-Host "  $os base image already exists. Skipping: $($img.Path)"
    } else {
        Write-Host "  $os -> VHDX conversion (Disk $($img.DiskNumber))... (this may take a few minutes)"
        New-VHD -Path $img.Path -SourceDisk $img.DiskNumber -Dynamic
        Write-Host "  Done: $($img.Path)"
    }
}

# ============================================================================
# Step 3: Copy VHDX per VM
# ============================================================================
Write-Host ""
Write-Host "========================================="
Write-Host "Step 3: Copying VHDX per VM"
Write-Host "========================================="

foreach ($vmConfig in $nestedVMs) {
    $vmVhdx = "$vhdxPath\$($vmConfig.Name).vhdx"
    $baseVhdx = $baseImages[$vmConfig.OSVersion].Path

    if (Test-Path $vmVhdx) {
        Write-Host "  $($vmConfig.Name).vhdx already exists. Skipping."
    } else {
        Write-Host "  $baseVhdx -> $vmVhdx copying..."
        Copy-Item -Path $baseVhdx -Destination $vmVhdx
        Write-Host "  Done: $($vmConfig.Name).vhdx"
    }
}

# ============================================================================
# Step 4: Create nested VMs
# ============================================================================
Write-Host ""
Write-Host "========================================="
Write-Host "Step 4: Creating nested VMs"
Write-Host "========================================="

# Verify VM switch exists
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    throw "VM switch '$switchName' not found. Run Setup-NestedNetwork.ps1 first."
}

foreach ($vmConfig in $nestedVMs) {
    $vmVhdx = "$vhdxPath\$($vmConfig.Name).vhdx"
    $sourceDiskNumber = $baseImages[$vmConfig.OSVersion].DiskNumber
    $generation = $generationMap[$sourceDiskNumber]

    if (Get-VM -Name $vmConfig.Name -ErrorAction SilentlyContinue) {
        Write-Host "  $($vmConfig.Name) already exists. Skipping."
        continue
    }

    Write-Host "  Creating $($vmConfig.Name)..."
    Write-Host "    Role:   $($vmConfig.Description)"
    Write-Host "    Gen:    Gen $generation"
    Write-Host "    Memory: $($vmConfig.MemoryBytes / 1GB) GB"
    Write-Host "    vCPU:   $($vmConfig.ProcessorCount)"
    Write-Host "    VHDX:   $vmVhdx"

    # Create VM
    $newVmParams = @{
        Name               = $vmConfig.Name
        Path               = $vmPath
        Generation         = $generation
        MemoryStartupBytes = $vmConfig.MemoryBytes
        VHDPath            = $vmVhdx
        SwitchName         = $switchName
    }
    $vm = New-VM @newVmParams

    # Processor settings
    Set-VM -Name $vmConfig.Name -ProcessorCount $vmConfig.ProcessorCount

    # Disable dynamic memory (for stability)
    Set-VM -Name $vmConfig.Name -StaticMemory

    # Disable checkpoints (for performance)
    Set-VM -Name $vmConfig.Name -CheckpointType Disabled

    # For Gen2, set secure boot template for Microsoft Windows
    if ($generation -eq 2) {
        Set-VMFirmware -VMName $vmConfig.Name -SecureBootTemplate MicrosoftWindows
    }

    Write-Host "  $($vmConfig.Name) created successfully"
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "========================================="
Write-Host "=== Nested VM creation complete ==="
Write-Host "========================================="
Write-Host ""
Write-Host "Created VMs:"
Get-VM | Where-Object { $_.Name -in $nestedVMs.Name } |
    Format-Table Name, State, @{N='MemoryGB'; E={$_.MemoryStartup/1GB}}, ProcessorCount -AutoSize

Write-Host "Next steps:"
Write-Host "  1. Start each VM in Hyper-V Manager (Start-VM -Name <vm-name>)"
Write-Host "  2. Complete the initial OS setup (OOBE)"
Write-Host "  3. Set static IP addresses:"
Write-Host "       vm-ad01  : 192.168.100.10/24  GW: 192.168.100.1"
Write-Host "       vm-app01 : 192.168.100.11/24  GW: 192.168.100.1  DNS: 192.168.100.10"
Write-Host "       vm-sql01 : 192.168.100.12/24  GW: 192.168.100.1  DNS: 192.168.100.10"
Write-Host "  4. Install AD DS on vm-ad01"
Write-Host "  5. Join vm-app01 and vm-sql01 to the domain"
Write-Host ""
Write-Host "Cleanup upload disks (run from local PC):"
Write-Host "  az vm disk detach -g rg-onprem-migration --vm-name vm-onprem-hv01 -n disk-upload-ws2022"
Write-Host "  az vm disk detach -g rg-onprem-migration --vm-name vm-onprem-hv01 -n disk-upload-ws2019"
Write-Host "  az disk delete -g rg-onprem-migration -n disk-upload-ws2022 --yes"
Write-Host "  az disk delete -g rg-onprem-migration -n disk-upload-ws2019 --yes"
