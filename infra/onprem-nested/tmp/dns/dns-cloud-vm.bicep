// ============================================================================
// Cloud VM DNS Module
// - Private DNS Zone (azure.internal) for Cloud VM name resolution from on-prem
// - Hub VNet link (no auto-registration - Hub has no VMs)
// - Spoke VNet links (auto-registration enabled - VM A records created automatically)
// ============================================================================

param hubVnetName string = 'vnet-hub'
param cloudDnsZone string = 'azure.internal'
param spokeVnetLinks array = []

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
}

// --- Private DNS Zone ---
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: cloudDnsZone
  location: 'global'
}

// --- Hub VNet link (no auto-registration) ---
resource hubVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'link-vnet-hub'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: hubVnet.id
    }
    registrationEnabled: false
  }
}

// --- Spoke VNet links (auto-registration enabled) ---
resource spokeVnetLinksRes 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for link in spokeVnetLinks: {
    parent: privateDnsZone
    name: link.name
    location: 'global'
    properties: {
      virtualNetwork: {
        id: link.vnetId
      }
      registrationEnabled: true
    }
  }
]

output privateDnsZoneId string = privateDnsZone.id
