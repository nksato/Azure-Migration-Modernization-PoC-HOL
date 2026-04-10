# =============================================================================
# Upload-VHDs.ps1
# Upload VHD files from local PC as Azure Managed Disks and attach them
# to the Hyper-V host VM.
#
# Prerequisites:
#   - Azure CLI (az) installed and logged in
#   - azcopy installed (must be in PATH)
#   - VHDs must be fixed-size format (convert dynamic VHD/VHDX beforehand)
#
# Pre-conversion (if needed):
#   Convert-VHD -Path .\dynamic.vhdx -DestinationPath .\fixed.vhd -VHDType Fixed
# =============================================================================

param(
    [Parameter(Mandatory)]
    [string]$VhdPathWs2022,

    [Parameter(Mandatory)]
    [string]$VhdPathWs2019,

    [string]$ResourceGroupName = 'rg-onprem-nested',
    [string]$VmName = 'vm-onprem-hv01',
    [string]$Location = 'japaneast'
)

$ErrorActionPreference = 'Stop'

# Ensure azcopy is in PATH (winget installs may not be visible in current session)
$env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'User') + ';' + [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')

if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) {
    throw "azcopy not found. Install it with: winget install Microsoft.Azure.AZCopy.10"
}

function Upload-VhdAsManagedDisk {
    param(
        [string]$DiskName,
        [string]$VhdPath,
        [int]$Lun
    )

    if (-not (Test-Path $VhdPath)) {
        throw "VHD file not found: $VhdPath"
    }

    $fileSize = (Get-Item $VhdPath).Length
    $fileSizeGB = [math]::Round($fileSize / 1GB, 2)
    Write-Host "========================================"
    Write-Host "Upload: $VhdPath ($fileSizeGB GB) -> $DiskName (LUN $Lun)"
    Write-Host "========================================"

    # Step 1: Create Managed Disk (for upload)
    Write-Host "[1/5] Creating Managed Disk: $DiskName"
    az disk create `
        --resource-group $ResourceGroupName `
        --name $DiskName `
        --upload-type Upload `
        --upload-size-bytes $fileSize `
        --sku Standard_LRS `
        --os-type Windows `
        --location $Location `
        --output none

    if ($LASTEXITCODE -ne 0) { throw "Failed to create Managed Disk: $DiskName" }

    # Step 2: Get write SAS URL
    Write-Host "[2/5] Generating SAS URL..."
    $sasUrl = az disk grant-access `
        --resource-group $ResourceGroupName `
        --name $DiskName `
        --access-level Write `
        --duration-in-seconds 86400 `
        --query accessSAS -o tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sasUrl)) {
        throw "Failed to get SAS URL: $DiskName"
    }

    # Step 3: Upload VHD via azcopy
    Write-Host "[3/5] Uploading VHD (this may take some time depending on file size)..."
    & azcopy copy $VhdPath $sasUrl --blob-type PageBlob

    if ($LASTEXITCODE -ne 0) { throw "VHD upload failed: $DiskName" }

    # Step 4: Revoke SAS access
    Write-Host "[4/5] Revoking upload access..."
    az disk revoke-access `
        --resource-group $ResourceGroupName `
        --name $DiskName `
        --output none

    # Step 5: Attach to VM
    Write-Host "[5/5] Attaching to VM ($VmName) at LUN $Lun..."
    az vm disk attach `
        --resource-group $ResourceGroupName `
        --vm-name $VmName `
        --name $DiskName `
        --lun $Lun `
        --output none

    if ($LASTEXITCODE -ne 0) { throw "Failed to attach disk: $DiskName" }

    Write-Host "Done: $DiskName`n"
}

# --- Main ---
Write-Host ""
Write-Host "=== VHD Upload Started ==="
Write-Host "Resource Group: $ResourceGroupName"
Write-Host "Target VM:      $VmName"
Write-Host ""

# Windows Server 2022 VHD -> LUN 1 (for AD server)
Upload-VhdAsManagedDisk -DiskName 'disk-upload-ws2022' -VhdPath $VhdPathWs2022 -Lun 1

# Windows Server 2019 VHD -> LUN 2 (for App / SQL servers)
Upload-VhdAsManagedDisk -DiskName 'disk-upload-ws2019' -VhdPath $VhdPathWs2019 -Lun 2

Write-Host "========================================="
Write-Host "=== All uploads completed ==="
Write-Host "========================================="
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Connect to $VmName via Bastion RDP"
Write-Host "  2. Run .\scripts\Create-NestedVMs.ps1 in an elevated PowerShell"
Write-Host ""
Write-Host "Cleanup upload disks (after nested VM creation):"
Write-Host "  az vm disk detach -g $ResourceGroupName --vm-name $VmName -n disk-upload-ws2022"
Write-Host "  az vm disk detach -g $ResourceGroupName --vm-name $VmName -n disk-upload-ws2019"
Write-Host "  az disk delete -g $ResourceGroupName -n disk-upload-ws2022 --yes"
Write-Host "  az disk delete -g $ResourceGroupName -n disk-upload-ws2019 --yes"
