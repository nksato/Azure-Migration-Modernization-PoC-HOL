// ============================================================
// Azure Firewall Basic + Policy
// ============================================================

param location string
param tags object
param hubVnetName string

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-afw-hub'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource pipMgmt 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-afw-hub-mgmt'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-01-01' = {
  name: 'afwp-hub'
  location: location
  tags: tags
  properties: {
    sku: {
      tier: 'Basic'
    }
  }
}

resource networkRuleCollection 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-01-01' = {
  parent: firewallPolicy
  name: 'DefaultNetworkRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowInternalTraffic'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'OnPrem-to-Spokes'
            sourceAddresses: ['10.0.0.0/16']
            destinationAddresses: ['10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16']
            destinationPorts: ['*']
            ipProtocols: ['Any']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Spokes-to-OnPrem'
            sourceAddresses: ['10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16']
            destinationAddresses: ['10.0.0.0/16']
            destinationPorts: ['*']
            ipProtocols: ['Any']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Spoke-to-Spoke'
            sourceAddresses: ['10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16']
            destinationAddresses: ['10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16']
            destinationPorts: ['*']
            ipProtocols: ['Any']
          }
        ]
      }
    ]
  }
}

resource appRuleCollection 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-01-01' = {
  parent: firewallPolicy
  name: 'DefaultApplicationRuleCollectionGroup'
  dependsOn: [networkRuleCollection]
  properties: {
    priority: 300
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowOutbound'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-WindowsUpdate'
            sourceAddresses: ['*']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: ['*.windowsupdate.com', '*.update.microsoft.com', '*.download.windowsupdate.com']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-AzureServices'
            sourceAddresses: ['*']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: ['*.azure.com', '*.microsoft.com', '*.msftauth.net', '*.msauth.net']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-ArcEndpoints'
            sourceAddresses: ['10.0.0.0/16']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              '*.guestconfiguration.azure.com'
              '*.his.arc.azure.com'
              '*.dp.kubernetesconfiguration.azure.com'
              'management.azure.com' // #disable no-hardcoded-env-urls - Arc requires specific endpoints
              'login.microsoftonline.com' // #disable no-hardcoded-env-urls - Arc requires specific endpoints
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-01-01' = {
  name: 'afw-hub'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName, 'AzureFirewallSubnet')
          }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'fw-mgmt-ipconfig'
      properties: {
        publicIPAddress: {
          id: pipMgmt.id
        }
        subnet: {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName, 'AzureFirewallManagementSubnet')
        }
      }
    }
  }
  dependsOn: [networkRuleCollection, appRuleCollection]
}

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
