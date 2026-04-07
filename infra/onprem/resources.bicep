// ============================================================
// 疑似オンプレミス環境
// ============================================================
// NAT Gateway で送信インターネットアクセスを提供し、
// defaultOutboundAccess を無効化しています。
// https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access
// ============================================================

@description('管理者ユーザー名')
param adminUsername string = 'labadmin'

@description('管理者パスワード')
@secure()
param adminPassword string

@description('リソースの場所')
param location string = resourceGroup().location

@description('Active Directory ドメイン名')
param domainName string = 'lab.local'

// タグ定義
var dcTags = { Role: 'DomainController' }
var dbTags = { Role: 'Database' }
var webTags = { Role: 'WebServer' }
var sharedTags = { Role: 'Shared' }

// NSG: 閉域ネットワーク — VNet 内通信のみ許可 (Inbound のみ制限)
resource serverNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-server'
  location: location
  tags: sharedTags
  properties: {
    securityRules: [
      {
        name: 'AllowVNetInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// NAT Gateway — VM の送信インターネットアクセス用
resource natGwPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-ng-onprem'
  location: location
  tags: sharedTags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGw 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'ng-onprem'
  location: location
  tags: sharedTags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natGwPip.id
      }
    ]
  }
}

// 疑似オンプレミス VNet
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-onprem'
  location: location
  tags: sharedTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    dhcpOptions: {
      dnsServers: [
        '10.0.1.4' // AD サーバをドメイン DNS として使用
      ]
    }
    subnets: [
      {
        name: 'ServerSubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          defaultOutboundAccess: false
          natGateway: {
            id: natGw.id
          }
          networkSecurityGroup: {
            id: serverNsg.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.254.0/26'
        }
      }
    ]
  }
}

resource serverSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'ServerSubnet'
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'AzureBastionSubnet'
}

// Azure Bastion — 閉域ネットワークへの管理アクセス
resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-bas-onprem'
  location: location
  tags: sharedTags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'bas-onprem'
  location: location
  tags: sharedTags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          publicIPAddress: {
            id: bastionPip.id
          }
          subnet: {
            id: bastionSubnet.id
          }
        }
      }
    ]
  }
}

// ============================================================
// AD サーバ (Windows Server 2022 / Active Directory)
// ============================================================

resource adNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-vm-onprem-ad'
  location: location
  tags: dcTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.4'
        }
      }
    ]
  }
}

resource adVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-onprem-ad'
  location: location
  tags: dcTags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v3'
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
        sku: '2022-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: adNic.id
        }
      ]
    }
  }
}

// AD DS 役割インストール + ドメインコントローラー昇格
resource adSetupExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: adVm
  name: 'ADSetup'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "Install-WindowsFeature -Name AD-Domain-Services,DNS -IncludeManagementTools; Import-Module ADDSDeployment; Install-ADDSForest -DomainName ${domainName} -SafeModeAdministratorPassword (ConvertTo-SecureString \'${adminPassword}\' -AsPlainText -Force) -DomainNetbiosName \'LAB\' -InstallDNS -Force -NoRebootOnCompletion; shutdown /r /t 60"'
    }
  }
}

// ============================================================
// SQL サーバ (SQL Server 2019 Developer on Windows Server 2019)
// ============================================================

resource sqlNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-vm-onprem-sql'
  location: location
  tags: dbTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.5'
        }
      }
    ]
  }
}

resource sqlVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-onprem-sql'
  location: location
  tags: dbTags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v3'
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
        offer: 'sql2019-ws2019'
        sku: 'sqldev'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          diskSizeGB: 128
          createOption: 'Empty'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: sqlNic.id
        }
      ]
    }
  }
}

// SQL Server VM 固有の設定 (データドライブ構成)
resource sqlVmConfig 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: sqlVm.name
  location: location
  tags: dbTags
  properties: {
    virtualMachineResourceId: sqlVm.id
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

// SQL サーバのドメイン参加 (AD 構築完了後に実行)
resource sqlDomainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: sqlVm
  name: 'DomainJoin'
  location: location
  dependsOn: [
    adSetupExtension
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
// Web サーバ (Windows Server 2022 / IIS + ASP.NET)
// ============================================================

resource webNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-vm-onprem-web'
  location: location
  tags: webTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.6'
        }
      }
    ]
  }
}

resource webVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-onprem-web'
  location: location
  tags: webTags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v3'
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
        sku: '2019-Datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: webNic.id
        }
      ]
    }
  }
}

// IIS + ASP.NET 4.8 インストール
resource webIisExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: webVm
  name: 'IISSetup'
  location: location
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

// Web サーバのドメイン参加 (AD 構築完了後に実行)
resource webDomainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: webVm
  name: 'DomainJoin'
  location: location
  dependsOn: [
    adSetupExtension
    webIisExtension
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
// Outputs
// ============================================================

output bastionName string = bastion.name
output vnetName string = vnet.name
output adServerPrivateIp string = '10.0.1.4'
output sqlServerPrivateIp string = '10.0.1.5'
output webServerPrivateIp string = '10.0.1.6'
