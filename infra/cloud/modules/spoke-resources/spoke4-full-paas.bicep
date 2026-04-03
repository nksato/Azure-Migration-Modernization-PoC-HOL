// ============================================================
// Spoke4: フル PaaS リソース (App Service + Azure SQL + PE)
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

param vnetName string = 'vnet-spoke4'

// App Service Plan
resource asp 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-spoke4'
  location: location
  tags: tags
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: false
  }
}

// App Service
resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: 'app-spoke4'
  location: location
  tags: tags
  properties: {
    serverFarmId: asp.id
    siteConfig: {
      netFrameworkVersion: 'v8.0'
      alwaysOn: true
    }
    virtualNetworkSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-appservice')
  }
}

// Azure SQL Database
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-spoke4'
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
  name: 'sqldb-spoke4'
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
  name: 'link-spoke4'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: resourceId('Microsoft.Network/virtualNetworks', vnetName)
    }
    registrationEnabled: false
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pep-spoke4-sql'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-pep')
    }
    privateLinkServiceConnections: [
      {
        name: 'pep-spoke4-sql'
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

output appServiceUrl string = 'https://${app.properties.defaultHostName}'
