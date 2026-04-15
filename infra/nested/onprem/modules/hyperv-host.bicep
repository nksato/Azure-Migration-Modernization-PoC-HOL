// ============================================================================
// Hyper-V Host VM Module
// - Windows Server 2022 with nested virtualization
// - Data disk for Hyper-V VM storage
// - Run Command to install Hyper-V role and initialize data disk
// ============================================================================

param location string
param vmName string
param subnetId string
param adminUsername string

@secure()
param adminPassword string

@description('VM size supporting nested virtualization')
param vmSize string = 'Standard_E4s_v5'

param osDiskSizeGB int = 128
param dataDiskSizeGB int = 256

// ----------------------------------------------------------------------------
// NIC (private IP only - no public IP)
// ----------------------------------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${vmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Virtual Machine
// ----------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: take(vmName, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${vmName}'
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: 'datadisk-${vmName}'
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGB
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// ----------------------------------------------------------------------------
// Run Command - Install Hyper-V and initialize data disk
// ----------------------------------------------------------------------------
resource installHyperV 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'install-hyperv'
  location: location
  properties: {
    source: {
      script: '''
        # Initialize data disk (F: drive)
        $disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' }
        if ($disk) {
          $disk | Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -DriveLetter F -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel "HyperV-Data" -Confirm:$false
        }

        # Create Hyper-V default folders on data disk
        New-Item -Path "F:\Hyper-V\Virtual Hard Disks" -ItemType Directory -Force
        New-Item -Path "F:\Hyper-V\Virtual Machines" -ItemType Directory -Force
        New-Item -Path "F:\ISO" -ItemType Directory -Force

        # Install Hyper-V role and management tools
        Install-WindowsFeature -Name Hyper-V -IncludeManagementTools

        # Install DHCP role for nested VM networking
        Install-WindowsFeature -Name DHCP -IncludeManagementTools

        # Restart to complete Hyper-V installation
        shutdown /r /t 30 /c "Restarting to complete Hyper-V installation"
      '''
    }
    timeoutInSeconds: 600
  }
}

// ----------------------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------------------
output vmId string = vm.id
output vmName string = vm.name
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
