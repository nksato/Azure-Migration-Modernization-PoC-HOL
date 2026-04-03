// ============================================================
// Azure Migration & Modernization PoC - Main Bicep Template
// ============================================================
// Deploy to Azure ボタンで一括デプロイされるエントリポイント
// Nested Hyper-V なし: DC01/APP01/DB01 を直接 Azure VM としてデプロイ
// ============================================================

targetScope = 'subscription'

// ============================================================
// Parameters
// ============================================================

@description('デプロイリージョン')
param location string = 'japaneast'

@description('VM 管理者ユーザー名')
param adminUsername string = 'azureadmin'

@description('VM 管理者パスワード')
@secure()
param adminPassword string

@description('Active Directory ドメイン名')
param domainName string = 'contoso.local'

@description('Azure Firewall をデプロイするか')
param deployFirewall bool = true

@description('VPN Gateway をデプロイするか')
param deployVpnGateway bool = true

@description('Azure Bastion をデプロイするか')
param deployBastion bool = true

// ============================================================
// Variables
// ============================================================

var defaultTags = {
  Environment: 'PoC'
  Project: 'Migration-Handson'
  SecurityControl: 'Ignore'
}

// ============================================================
// Resource Groups
// ============================================================

resource rgOnprem 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-onprem'
  location: location
  tags: defaultTags
}

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-hub'
  location: location
  tags: defaultTags
}

resource rgSpoke1 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke1'
  location: location
  tags: defaultTags
}

resource rgSpoke2 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke2'
  location: location
  tags: defaultTags
}

resource rgSpoke3 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke3'
  location: location
  tags: defaultTags
}

resource rgSpoke4 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-spoke4'
  location: location
  tags: defaultTags
}

// ============================================================
// Network Modules
// ============================================================

module onpremVnet 'modules/network/onprem-vnet.bicep' = {
  name: 'deploy-onprem-vnet'
  scope: rgOnprem
  params: {
    location: location
    tags: defaultTags
  }
}

module hubVnet 'modules/network/hub-vnet.bicep' = {
  name: 'deploy-hub-vnet'
  scope: rgHub
  params: {
    location: location
    tags: defaultTags
  }
}

module spokeVnets 'modules/network/spoke-vnets.bicep' = {
  name: 'deploy-spoke-vnets'
  scope: rgSpoke1
  params: {
    location: location
    tags: defaultTags
    spoke1RgName: rgSpoke1.name
    spoke2RgName: rgSpoke2.name
    spoke3RgName: rgSpoke3.name
    spoke4RgName: rgSpoke4.name
  }
}

module peering 'modules/network/peering.bicep' = {
  name: 'deploy-peering'
  scope: rgHub
  params: {
    hubVnetName: hubVnet.outputs.vnetName
    hubVnetId: hubVnet.outputs.vnetId
    spoke1VnetId: spokeVnets.outputs.spoke1VnetId
    spoke2VnetId: spokeVnets.outputs.spoke2VnetId
    spoke3VnetId: spokeVnets.outputs.spoke3VnetId
    spoke4VnetId: spokeVnets.outputs.spoke4VnetId
    spoke1VnetName: spokeVnets.outputs.spoke1VnetName
    spoke2VnetName: spokeVnets.outputs.spoke2VnetName
    spoke3VnetName: spokeVnets.outputs.spoke3VnetName
    spoke4VnetName: spokeVnets.outputs.spoke4VnetName
    spoke1RgName: rgSpoke1.name
    spoke2RgName: rgSpoke2.name
    spoke3RgName: rgSpoke3.name
    spoke4RgName: rgSpoke4.name
  }
}

module vpnGateway 'modules/network/vpn-gateway.bicep' = if (deployVpnGateway) {
  name: 'deploy-vpn-gateway'
  scope: rgHub
  params: {
    location: location
    tags: defaultTags
    hubVnetName: hubVnet.outputs.vnetName
    onpremVnetName: onpremVnet.outputs.vnetName
    onpremRgName: rgOnprem.name
  }
}

module firewall 'modules/network/firewall.bicep' = if (deployFirewall) {
  name: 'deploy-firewall'
  scope: rgHub
  params: {
    location: location
    tags: defaultTags
    hubVnetName: hubVnet.outputs.vnetName
  }
}

module bastion 'modules/network/bastion.bicep' = if (deployBastion) {
  name: 'deploy-bastion'
  scope: rgOnprem
  params: {
    location: location
    tags: defaultTags
    vnetName: onpremVnet.outputs.vnetName
    bastionName: 'bas-onprem'
    pipName: 'pip-bas-onprem'
  }
}

module routeTable 'modules/network/route-table.bicep' = if (deployFirewall) {
  name: 'deploy-route-table'
  scope: rgHub
  params: {
    location: location
    tags: defaultTags
    firewallPrivateIp: deployFirewall ? firewall.outputs.firewallPrivateIp : ''
    spoke1RgName: rgSpoke1.name
    spoke2RgName: rgSpoke2.name
    spoke3RgName: rgSpoke3.name
    spoke4RgName: rgSpoke4.name
  }
}

// ============================================================
// Compute Module (疑似オンプレ VM)
// ============================================================

module onpremVms 'modules/compute/onprem-vms.bicep' = {
  name: 'deploy-onprem-vms'
  scope: rgOnprem
  params: {
    location: location
    tags: defaultTags
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: onpremVnet.outputs.onpremSubnetId
    domainName: domainName
  }
}

// ============================================================
// Governance Modules
// ============================================================

module logAnalytics 'modules/governance/log-analytics.bicep' = {
  name: 'deploy-log-analytics'
  scope: rgHub
  params: {
    location: location
    tags: defaultTags
  }
}

module policy 'modules/governance/policy.bicep' = {
  name: 'deploy-policy'
  params: {
    location: location
  }
}

module defender 'modules/governance/defender.bicep' = {
  name: 'deploy-defender'
  params: {
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

// ============================================================
// Migration Module
// ============================================================

module migrateProject 'modules/migration/migrate-project.bicep' = {
  name: 'deploy-migrate-project'
  scope: rgHub
  params: {
    location: location
    tags: defaultTags
  }
}

// ============================================================
// Outputs
// ============================================================

output onpremVnetId string = onpremVnet.outputs.vnetId
output hubVnetId string = hubVnet.outputs.vnetId
output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId
