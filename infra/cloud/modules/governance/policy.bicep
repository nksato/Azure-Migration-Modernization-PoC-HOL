// ============================================================
// Azure Policy 割り当て（サブスクリプションスコープ）
// ============================================================

targetScope = 'subscription'

param location string

// Allowed locations
resource allowedLocations 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'policy-allowed-locations'
  properties: {
    displayName: 'Allowed locations'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
    parameters: {
      listOfAllowedLocations: {
        value: [
          'japaneast'
          'japanwest'
        ]
      }
    }
  }
}

// Require tag on resource group (Environment)
resource requireTagOnRg 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'policy-require-env-tag-rg'
  properties: {
    displayName: 'Require Environment tag on resource groups'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '96670d01-0a4d-4649-9c89-2d3abc0a5025')
    parameters: {
      tagName: {
        value: 'Environment'
      }
    }
  }
}

// Inherit tag from RG (Environment)
resource inheritTagFromRg 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'policy-inherit-env-tag'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Inherit Environment tag from resource group'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'cd3aa116-8754-49c9-a813-ad46512ece54')
    parameters: {
      tagName: {
        value: 'Environment'
      }
    }
  }
}
