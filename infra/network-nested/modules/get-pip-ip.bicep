// ============================================================================
// Get Public IP Address
// Retrieves the IP address from an existing Public IP resource
// ============================================================================

param pipName string

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' existing = {
  name: pipName
}

output ipAddress string = pip.properties.ipAddress
