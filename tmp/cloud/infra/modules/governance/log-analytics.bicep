// ============================================================
// Log Analytics Workspace
// ============================================================

param location string
param tags object

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-hub'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
