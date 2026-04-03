// ============================================================
// Spoke VNet 単体（spoke-vnets.bicep から呼び出し）
// ============================================================

param location string
param tags object
param vnetName string
param vnetAddressPrefix string
param subnets array

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = [
  for subnet in subnets: {
    name: 'nsg-${subnet.name}'
    location: location
    tags: tags
    properties: {
      securityRules: []
    }
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      for (subnet, i) in subnets: {
        name: subnet.name
        properties: {
          addressPrefix: subnet.addressPrefix
          networkSecurityGroup: {
            id: nsg[i].id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
