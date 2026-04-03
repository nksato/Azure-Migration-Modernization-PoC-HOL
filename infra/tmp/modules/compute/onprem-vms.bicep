// ============================================================
// 疑似オンプレ VM（DC01, APP01, DB01）— 直接 Azure VM
// ============================================================
// AD DS 構築 → ドメイン参加 (DB01, APP01) の依存関係あり
// ============================================================

param location string
param tags object
param adminUsername string

@secure()
param adminPassword string

param subnetId string

@description('Active Directory ドメイン名')
param domainName string = 'contoso.local'

var domainNetBIOSName = toUpper(split(domainName, '.')[0])

// ============================================================
// DC01 — AD DS / DNS (Windows Server 2022)
// ============================================================

resource nicDc01 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-dc01'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.4'
        }
      }
    ]
  }
}

resource vmDc01 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'DC01'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    osProfile: {
      computerName: 'DC01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicDc01.id
        }
      ]
    }
  }
}

// AD DS インストール + フォレスト作成 + 再起動
resource dc01Setup 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vmDc01
  name: 'setup-ad'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "Install-WindowsFeature -Name AD-Domain-Services,DNS -IncludeManagementTools; Import-Module ADDSDeployment; Install-ADDSForest -DomainName ${domainName} -SafeModeAdministratorPassword (ConvertTo-SecureString \'${adminPassword}\' -AsPlainText -Force) -DomainNetbiosName \'${domainNetBIOSName}\' -InstallDNS -Force -NoRebootOnCompletion; shutdown /r /t 60"'
    }
  }
}

// ============================================================
// APP01 — IIS + ASP.NET 4.8 (Windows Server 2022)
// ============================================================

resource nicApp01 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-app01'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.6'
        }
      }
    ]
  }
}

resource vmApp01 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'APP01'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    osProfile: {
      computerName: 'APP01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicApp01.id
        }
      ]
    }
  }
}

// IIS + ASP.NET 4.8 インストール
resource app01IisSetup 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vmApp01
  name: 'setup-iis'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "Install-WindowsFeature -Name Web-Server,Web-Asp-Net45,Web-Mgmt-Tools,NET-Framework-45-ASPNET -IncludeManagementTools"'
    }
  }
}

// APP01 ドメイン参加 (AD 構築完了後)
resource app01DomainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vmApp01
  name: 'domain-join'
  location: location
  dependsOn: [
    dc01Setup
    app01IisSetup
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      User: '${domainName}\\${adminUsername}'
      Restart: 'true'
      Options: '3'
    }
    protectedSettings: {
      Password: adminPassword
    }
  }
}

// ============================================================
// DB01 — SQL Server 2022 Developer (Windows Server 2022)
// ============================================================

resource nicDb01 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-db01'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.5'
        }
      }
    ]
  }
}

resource vmDb01 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'DB01'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    osProfile: {
      computerName: 'DB01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: 'sqldev-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 128
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicDb01.id
        }
      ]
    }
  }
}

resource sqlVmDb01 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: 'DB01'
  location: location
  tags: tags
  properties: {
    virtualMachineResourceId: vmDb01.id
    sqlManagement: 'Full'
    sqlServerLicenseType: 'PAYG'
    storageConfigurationSettings: {
      diskConfigurationType: 'NEW'
      sqlDataSettings: {
        luns: [0]
        defaultFilePath: 'F:\\SQLData'
      }
      sqlLogSettings: {
        luns: [0]
        defaultFilePath: 'F:\\SQLLog'
      }
    }
  }
}

// DB01 ドメイン参加 (AD 構築完了後)
resource db01DomainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vmDb01
  name: 'domain-join'
  location: location
  dependsOn: [
    dc01Setup
    sqlVmDb01
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      User: '${domainName}\\${adminUsername}'
      Restart: 'true'
      Options: '3'
    }
    protectedSettings: {
      Password: adminPassword
    }
  }
}

output dc01VmId string = vmDc01.id
output app01VmId string = vmApp01.id
output db01VmId string = vmDb01.id
