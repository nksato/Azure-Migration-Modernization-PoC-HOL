// ============================================================
// Azure Migrate プロジェクト
// ============================================================

param location string
param tags object

resource migrateProject 'Microsoft.Migrate/migrateProjects@2020-06-01-preview' = {
  name: 'migr-project'
  location: location
  tags: tags
  properties: {}
}

output projectId string = migrateProject.id
