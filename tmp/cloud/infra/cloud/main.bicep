// Azure Migration & Modernization PoC - Cloud Environment (Step 1)
// Subscription-level deployment: RGs + Hub & Spoke + management services
targetScope = 'subscription'

@description('Azure region for all resources')
param location string = deployment().location

@description('Deploy Azure Firewall')
param deployFirewall bool = true

@description('Deploy Azure Bastion')
param deployBastion bool = true

@description('Deploy VPN Gateway (Hub side)')
param deployVpnGateway bool = true

// Common tags applied to all resources
var commonTags = {
  Environment: 'PoC'
  SecurityControl: 'ignore'
}

// ============================================================
// Resource Groups
// ============================================================

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-hub'
  location: location
  tags: union(commonTags, { Purpose: 'Hub-SharedServices' })
}

resource rgSpoke1 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke1'
  location: location
  tags: union(commonTags, { Purpose: 'Spoke1-Rehost' })
}

resource rgSpoke2 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke2'
  location: location
  tags: union(commonTags, { Purpose: 'Spoke2-DBPaaS' })
}

resource rgSpoke3 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke3'
  location: location
  tags: union(commonTags, { Purpose: 'Spoke3-Container' })
}

resource rgSpoke4 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke4'
  location: location
  tags: union(commonTags, { Purpose: 'Spoke4-FullPaaS' })
}

// ============================================================
// Hub VNet (no peering yet - avoids circular dependency)
// ============================================================

module hubVnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: rgHub
  params: {
    name: 'vnet-hub'
    location: location
    addressPrefixes: ['10.10.0.0/16']
    tags: commonTags
    subnets: [
      { name: 'AzureFirewallSubnet', addressPrefix: '10.10.1.0/26' }
      { name: 'AzureFirewallManagementSubnet', addressPrefix: '10.10.4.0/26' }
      { name: 'AzureBastionSubnet', addressPrefix: '10.10.2.0/26' }
      { name: 'GatewaySubnet', addressPrefix: '10.10.255.0/27' }
      { name: 'snet-dns-inbound', addressPrefix: '10.10.5.0/28' }
      { name: 'snet-dns-outbound', addressPrefix: '10.10.5.16/28' }
    ]
  }
}

// ============================================================
// Log Analytics Workspace
// ============================================================

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  scope: rgHub
  params: {
    name: 'law-hub'
    location: location
    dataRetention: 30
    tags: commonTags
  }
}

// ============================================================
// DNS Private Resolver + Private DNS Zones
// ============================================================

module dnsResolver 'br/public:avm/res/network/dns-resolver:0.5.6' = {
  scope: rgHub
  params: {
    name: 'dnspr-hub'
    location: location
    tags: commonTags
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    inboundEndpoints: [
      {
        name: 'inbound'
        subnetResourceId: '${hubVnet.outputs.resourceId}/subnets/snet-dns-inbound'
      }
    ]
    outboundEndpoints: [
      {
        name: 'outbound'
        subnetResourceId: '${hubVnet.outputs.resourceId}/subnets/snet-dns-outbound'
      }
    ]
  }
}

// Private DNS Zone for Azure SQL (used by Spoke2/3/4 Private Endpoints)
module privateDnsZoneSql 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  scope: rgHub
  params: {
    name: 'privatelink.database.windows.net'
    tags: commonTags
    virtualNetworkLinks: [
      { virtualNetworkResourceId: hubVnet.outputs.resourceId, registrationEnabled: false }
      { virtualNetworkResourceId: spoke2Vnet.outputs.resourceId, registrationEnabled: false }
      { virtualNetworkResourceId: spoke3Vnet.outputs.resourceId, registrationEnabled: false }
      { virtualNetworkResourceId: spoke4Vnet.outputs.resourceId, registrationEnabled: false }
    ]
  }
}

// ============================================================
// Azure Firewall + Policy (deployed before Route Table)
// ============================================================

module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.4' = if (deployFirewall) {
  scope: rgHub
  params: {
    name: 'afwp-hub'
    location: location
    tier: 'Basic'
    threatIntelMode: 'Alert'
    tags: commonTags
    ruleCollectionGroups: [
      {
        name: 'DefaultNetworkRuleCollectionGroup'
        priority: 200
        ruleCollections: [
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'AllowInternalTraffic'
            priority: 100
            action: { type: 'Allow' }
            rules: [
              {
                ruleType: 'NetworkRule'
                name: 'OnPrem-to-Spokes'
                sourceAddresses: ['10.0.0.0/16']
                destinationAddresses: ['10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16']
                ipProtocols: ['Any']
                destinationPorts: ['*']
              }
              {
                ruleType: 'NetworkRule'
                name: 'Spokes-to-OnPrem'
                sourceAddresses: ['10.20.0.0/16', '10.21.0.0/16', '10.22.0.0/16', '10.23.0.0/16']
                destinationAddresses: ['10.0.0.0/16']
                ipProtocols: ['Any']
                destinationPorts: ['*']
              }
              {
                ruleType: 'NetworkRule'
                name: 'AllowDnsOutbound'
                sourceAddresses: ['10.0.0.0/8']
                destinationAddresses: ['*']
                ipProtocols: ['UDP', 'TCP']
                destinationPorts: ['53']
              }
            ]
          }
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'AllowInternetOutbound'
            priority: 200
            action: { type: 'Allow' }
            rules: [
              {
                ruleType: 'NetworkRule'
                name: 'AllowHttpsOutbound'
                sourceAddresses: ['10.0.0.0/8']
                destinationAddresses: ['*']
                ipProtocols: ['TCP']
                destinationPorts: ['443']
              }
              {
                ruleType: 'NetworkRule'
                name: 'AllowHttpOutbound'
                sourceAddresses: ['10.0.0.0/8']
                destinationAddresses: ['*']
                ipProtocols: ['TCP']
                destinationPorts: ['80']
              }
            ]
          }
        ]
      }
    ]
  }
}

module firewall 'br/public:avm/res/network/azure-firewall:0.10.0' = if (deployFirewall) {
  scope: rgHub
  params: {
    name: 'afw-hub'
    location: location
    azureSkuTier: 'Basic'
    tags: commonTags
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    firewallPolicyId: firewallPolicy.outputs.resourceId
    publicIPAddressObject: { name: 'pip-afw-hub' }
    managementIPAddressObject: { name: 'pip-afw-hub-mgmt' }
  }
}

// ============================================================
// Route Table (uses Firewall private IP)
// ============================================================

module routeTableSpokes 'br/public:avm/res/network/route-table:0.5.0' = if (deployFirewall) {
  scope: rgHub
  params: {
    name: 'rt-spokes-to-fw'
    location: location
    tags: commonTags
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.outputs.privateIp
        }
      }
      {
        name: 'onprem-to-firewall'
        properties: {
          addressPrefix: '10.0.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.outputs.privateIp
        }
      }
    ]
  }
}

// ============================================================
// Spoke VNets (created after Route Table is available)
// ============================================================

module spoke1Vnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: rgSpoke1
  params: {
    name: 'vnet-spoke1'
    location: location
    addressPrefixes: ['10.20.0.0/16']
    tags: commonTags
    subnets: [
      {
        name: 'snet-web'
        addressPrefix: '10.20.1.0/24'
        routeTableResourceId: deployFirewall ? routeTableSpokes.outputs.resourceId : null
      }
      {
        name: 'snet-db'
        addressPrefix: '10.20.2.0/24'
        routeTableResourceId: deployFirewall ? routeTableSpokes.outputs.resourceId : null
      }
    ]
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: deployVpnGateway
      }
    ]
  }
  dependsOn: [vpnGatewayHub]
}

module spoke2Vnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: rgSpoke2
  params: {
    name: 'vnet-spoke2'
    location: location
    addressPrefixes: ['10.21.0.0/16']
    tags: commonTags
    subnets: [
      {
        name: 'snet-web'
        addressPrefix: '10.21.1.0/24'
        routeTableResourceId: deployFirewall ? routeTableSpokes.outputs.resourceId : null
      }
      { name: 'snet-pep', addressPrefix: '10.21.2.0/24' }
    ]
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: deployVpnGateway
      }
    ]
  }
  dependsOn: [vpnGatewayHub]
}

module spoke3Vnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: rgSpoke3
  params: {
    name: 'vnet-spoke3'
    location: location
    addressPrefixes: ['10.22.0.0/16']
    tags: commonTags
    subnets: [
      {
        name: 'snet-aca'
        addressPrefix: '10.22.0.0/23'
        routeTableResourceId: deployFirewall ? routeTableSpokes.outputs.resourceId : null
      }
      { name: 'snet-pep', addressPrefix: '10.22.3.0/24' }
    ]
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: deployVpnGateway
      }
    ]
  }
  dependsOn: [vpnGatewayHub]
}

module spoke4Vnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: rgSpoke4
  params: {
    name: 'vnet-spoke4'
    location: location
    addressPrefixes: ['10.23.0.0/16']
    tags: commonTags
    subnets: [
      {
        name: 'snet-appservice'
        addressPrefix: '10.23.1.0/24'
        routeTableResourceId: deployFirewall ? routeTableSpokes.outputs.resourceId : null
        delegation: 'Microsoft.Web/serverFarms'
      }
      { name: 'snet-pep', addressPrefix: '10.23.2.0/24' }
    ]
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: deployVpnGateway
      }
    ]
  }
  dependsOn: [vpnGatewayHub]
}

// ============================================================
// VPN Gateway (depends on Hub VNet GatewaySubnet)
// ============================================================

module vpnGatewayHub 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = if (deployVpnGateway) {
  scope: rgHub
  params: {
    name: 'vpngw-hub'
    location: location
    gatewayType: 'Vpn'
    skuName: 'VpnGw1AZ'
    tags: commonTags
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    clusterSettings: { clusterMode: 'activePassiveNoBgp' }
  }
}

// ============================================================
// VNet Peering (Hub <-> Spokes, after VPN GW deployment)
// Re-deploys hub VNet with peering configuration
// ============================================================

module hubPeering 'br/public:avm/res/network/virtual-network:0.7.2' = {
  scope: rgHub
  params: {
    name: 'vnet-hub'
    location: location
    addressPrefixes: ['10.10.0.0/16']
    peerings: [
      {
        remoteVirtualNetworkResourceId: spoke1Vnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: deployVpnGateway
        useRemoteGateways: false
      }
      {
        remoteVirtualNetworkResourceId: spoke2Vnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: deployVpnGateway
        useRemoteGateways: false
      }
      {
        remoteVirtualNetworkResourceId: spoke3Vnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: deployVpnGateway
        useRemoteGateways: false
      }
      {
        remoteVirtualNetworkResourceId: spoke4Vnet.outputs.resourceId
        allowForwardedTraffic: true
        allowGatewayTransit: deployVpnGateway
        useRemoteGateways: false
      }
    ]
  }
  dependsOn: [vpnGatewayHub]
}

// ============================================================
// Azure Bastion
// ============================================================

module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = if (deployBastion) {
  scope: rgHub
  params: {
    name: 'bas-hub'
    location: location
    tags: commonTags
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    skuName: 'Basic'
  }
}

// ============================================================
// Security Center / Defender for Cloud
// ============================================================

module securityCenter 'br/public:avm/ptn/security/security-center:0.2.0' = {
  name: 'securityCenter'
  params: {
    virtualMachinesPricingTier: 'Standard'
    sqlServersPricingTier: 'Free'
    sqlServerVirtualMachinesPricingTier: 'Free'
    storageAccountsPricingTier: 'Free'
    appServicesPricingTier: 'Free'
    keyVaultsPricingTier: 'Free'
    dnsPricingTier: 'Free'
    armPricingTier: 'Free'
    containerRegistryPricingTier: 'Free'
    kubernetesServicePricingTier: 'Free'
  }
}

// ============================================================
// Azure Policy Assignments (subscription scope)
// ============================================================

module policyAllowedLocations 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = {
  name: 'policy-allowed-locations'
  params: {
    name: 'policy-allowed-locations'
    displayName: 'Allowed locations'
    description: 'Restrict resource deployment to Japan East and Japan West'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
    parameters: {
      listOfAllowedLocations: { value: ['japaneast', 'japanwest'] }
    }
  }
}

module policyStoragePublicAccess 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = {
  name: 'policy-storage-public-access'
  params: {
    name: 'policy-storage-no-public'
    displayName: 'Storage accounts should disable public network access'
    description: 'Audit storage accounts with public network access'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/b2982f36-99f2-4db5-8eff-283140c09693'
  }
}

module policySqlAuditing 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = {
  name: 'policy-sql-auditing'
  params: {
    name: 'policy-sql-auditing'
    displayName: 'SQL servers should have auditing enabled'
    description: 'Audit SQL servers without auditing'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/a6fb4358-5bf4-4ad7-ba82-2cd2f41ce5e9'
  }
}

module policySqlPublicAccess 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = {
  name: 'policy-sql-public-access'
  params: {
    name: 'policy-sql-no-public'
    displayName: 'Azure SQL Database should disable public network access'
    description: 'Audit Azure SQL databases with public network access'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/1b8ca024-1d5c-4dec-8995-b1a932b41780'
  }
}

module policyRequireTag 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = {
  name: 'policy-require-env-tag'
  params: {
    name: 'policy-require-env-tag'
    displayName: 'Require Environment tag on resource groups'
    description: 'Deny resource groups without Environment tag'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'
    parameters: { tagName: { value: 'Environment' } }
  }
}

module policyMgmtPorts 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = {
  name: 'policy-mgmt-ports'
  params: {
    name: 'policy-mgmt-ports-audit'
    displayName: 'Management ports should be closed on VMs'
    description: 'Audit VMs with open management ports'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/22730e10-96f6-4aac-ad84-9383d35b5917'
  }
}

module policyAppServicePublic 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = {
  name: 'policy-appservice-public'
  params: {
    name: 'policy-appservice-no-public'
    displayName: 'App Service should disable public network access'
    description: 'Audit App Service apps with public network access'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/1b5ef780-c53c-4a64-87f3-bb9c8c8094ba'
  }
}

// ============================================================
// Azure Portal Dashboard
// ============================================================

module pocDashboard './modules/dashboard.bicep' = {
  scope: rgHub
  params: {
    location: location
    subscriptionId: subscription().subscriptionId
    tags: commonTags
  }
}

// ============================================================
// Outputs
// ============================================================

output hubVnetId string = hubVnet.outputs.resourceId
output hubVnetName string = hubVnet.outputs.name
output spoke1VnetId string = spoke1Vnet.outputs.resourceId
output spoke2VnetId string = spoke2Vnet.outputs.resourceId
output spoke3VnetId string = spoke3Vnet.outputs.resourceId
output spoke4VnetId string = spoke4Vnet.outputs.resourceId
output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
output vpnGatewayId string = deployVpnGateway ? vpnGatewayHub.outputs.?resourceId ?? '' : ''
