// ============================================================================
// Network Module - Closed on-premises simulation network
// - VNet with Bastion subnet and on-prem subnet
// - Route table to block internet (0.0.0.0/0 -> None)
// - NSG with deny internet outbound on VM subnet
// - Required Bastion NSG rules
// ============================================================================

param location string
param vnetName string
param vnetAddressPrefix string = '10.0.0.0/16'
param bastionSubnetPrefix string = '10.0.0.0/26'
param onpremSubnetPrefix string = '10.0.1.0/24'

// ----------------------------------------------------------------------------
// Route Table - Block internet from on-prem subnet
// ----------------------------------------------------------------------------
resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-block-internet'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'block-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'None'
        }
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// NSG - On-prem subnet
// ----------------------------------------------------------------------------
resource nsgOnprem 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-onprem'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyInternetOutbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
        }
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// NSG - Azure Bastion subnet (required rules per Azure docs)
// ----------------------------------------------------------------------------
resource nsgBastion 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-bastion'
  location: location
  properties: {
    securityRules: [
      // --- Inbound ---
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowBastionHostCommunicationInbound'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      // --- Outbound ---
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
        }
      }
      {
        name: 'AllowBastionHostCommunicationOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowGetSessionInformationOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
        }
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Virtual Network
// ----------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: {
            id: nsgBastion.id
          }
        }
      }
      {
        name: 'snet-onprem'
        properties: {
          addressPrefix: onpremSubnetPrefix
          networkSecurityGroup: {
            id: nsgOnprem.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------------------
output vnetId string = vnet.id
output vnetName string = vnet.name
output bastionSubnetId string = vnet.properties.subnets[0].id
output onpremSubnetId string = vnet.properties.subnets[1].id
