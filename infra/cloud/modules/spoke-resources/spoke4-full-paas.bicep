// ============================================================
// Spoke4: フル PaaS リソース (App Service + Azure SQL + PE)
// - App Service / Azure SQL ともに Private Endpoint で閉域接続
// - DNS Zone は rg-hub の既存ゾーンを参照
// ============================================================

param location string = resourceGroup().location

// App Service は別リージョンにデプロイ可能（クォータ不足対策）
param appServiceLocation string = location

param tags object = {
  Environment: 'PoC'
  Project: 'Migration-Handson'
  SecurityControl: 'Ignore'
}

// グローバル一意にするためのサフィックス（サブスクリプション ID 先頭 8 文字等）
param nameSuffix string

param sqlAdminLogin string

@secure()
param sqlAdminPassword string

param vnetName string = 'vnet-spoke4'

// rg-hub にある既存 Private DNS Zone を参照するための RG 名
param dnsZoneResourceGroup string = 'rg-hub'

// ============================================================
// App Service Plan + App Service
// ============================================================

resource asp 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-spoke4-${nameSuffix}'
  location: appServiceLocation
  tags: tags
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: false // Windows
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: 'app-spoke4-${nameSuffix}'
  location: appServiceLocation
  tags: tags
  properties: {
    serverFarmId: asp.id
    siteConfig: {
      netFrameworkVersion: 'v4.0' // .NET Framework 4.8 互換
      alwaysOn: true
    }
    // VNet Integration はクォータ制約で省略。App Service → Azure SQL はパブリック経由。
    // DC01 → App Service のインバウンドは PE で閉域接続。
  }
}

// ============================================================
// Azure SQL Database
// ============================================================

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-spoke4-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    // BACPAC インポート時はパブリックアクセスが必要。インポート後に CLI で Disabled に変更
    publicNetworkAccess: 'Enabled'
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

// Azure SQL のファイアウォール規則（BACPAC インポート用に Azure サービスアクセスを許可）
resource sqlFirewallAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ============================================================
// Private Endpoint: Azure SQL
// ============================================================

resource pepSql 'Microsoft.Network/privateEndpoints@2024-01-01' = {
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

// DNS Zone Group — rg-hub の既存 privatelink.database.windows.net を参照
resource pepSqlDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: pepSql
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          #disable-next-line no-hardcoded-env-urls // Private DNS Zone 名であり URL ではない
          privateDnsZoneId: resourceId(subscription().subscriptionId, dnsZoneResourceGroup, 'Microsoft.Network/privateDnsZones', 'privatelink.database.windows.net')
        }
      }
    ]
  }
}

// ============================================================
// Private Endpoint: App Service
// ============================================================

resource pepApp 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pep-spoke4-app'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-pep')
    }
    privateLinkServiceConnections: [
      {
        name: 'pep-spoke4-app'
        properties: {
          privateLinkServiceId: app.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

// DNS Zone Group — rg-hub の privatelink.azurewebsites.net を参照（事前に CLI で作成）
resource pepAppDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: pepApp
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azurewebsites-net'
        properties: {
          privateDnsZoneId: resourceId(subscription().subscriptionId, dnsZoneResourceGroup, 'Microsoft.Network/privateDnsZones', 'privatelink.azurewebsites.net')
        }
      }
    ]
  }
}

// ============================================================
// Outputs
// ============================================================

output appServiceName string = app.name
output appServiceUrl string = 'https://${app.properties.defaultHostName}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlServerName string = sqlServer.name
