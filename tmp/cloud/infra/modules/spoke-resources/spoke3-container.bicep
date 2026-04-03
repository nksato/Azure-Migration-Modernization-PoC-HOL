// ============================================================
// Spoke3: コンテナ化リソース (ACA + ACR + Azure SQL + PE)
// ============================================================

param location string = resourceGroup().location
param tags object = {
  Environment: 'PoC'
  Project: 'Migration-Handson'
  SecurityControl: 'Ignore'
}

param sqlAdminLogin string

@secure()
param sqlAdminPassword string

param vnetName string = 'vnet-spoke3'

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: 'crspoke3'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// Container Apps Environment
resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-spoke3'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-aca')
      internal: false
    }
  }
}

// Azure SQL Database
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-spoke3'
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    publicNetworkAccess: 'Disabled'
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: 'sqldb-spoke3'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
}

// Private Endpoint for Azure SQL
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.database.windows.net'
  location: 'global'
  tags: tags
}

resource privateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'link-spoke3'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: resourceId('Microsoft.Network/virtualNetworks', vnetName)
    }
    registrationEnabled: false
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pep-spoke3-sql'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-pep')
    }
    privateLinkServiceConnections: [
      {
        name: 'pep-spoke3-sql'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: ['sqlServer']
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output acrLoginServer string = acr.properties.loginServer
output caeName string = cae.name
