// ============================================================
// Hub VNet（共有サービス）
// ============================================================

param location string
param tags object

var vnetName = 'vnet-hub'
var vnetAddressPrefix = '10.10.0.0/16'

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
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: '10.10.1.0/26'
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: '10.10.1.64/26'
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.10.2.0/26'
        }
      }
      {
        name: 'snet-management'
        properties: {
          addressPrefix: '10.10.3.0/24'
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.10.255.0/27'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output firewallSubnetId string = vnet.properties.subnets[0].id
output firewallMgmtSubnetId string = vnet.properties.subnets[1].id
output bastionSubnetId string = vnet.properties.subnets[2].id
output managementSubnetId string = vnet.properties.subnets[3].id
output gatewaySubnetId string = vnet.properties.subnets[4].id
