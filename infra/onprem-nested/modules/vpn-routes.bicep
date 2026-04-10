// ============================================================================
// VPN Routes for On-prem
// - Adds GatewaySubnet to existing VNet
// - Adds routes to existing route table for cloud CIDRs via VPN Gateway
// - Keeps 0.0.0.0/0 -> None (internet block) intact
// ============================================================================

param vnetName string
param gatewaySubnetPrefix string = '10.1.255.0/27'
param routeTableName string
param cloudAddressPrefixes array

// --- Add GatewaySubnet to on-prem VNet ---
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: gatewaySubnetPrefix
  }
}

// --- Add cloud routes to existing route table ---
resource routeTable 'Microsoft.Network/routeTables@2024-05-01' existing = {
  name: routeTableName
}

resource routes 'Microsoft.Network/routeTables/routes@2024-05-01' = [
  for prefix in cloudAddressPrefixes: {
    parent: routeTable
    name: 'vpn-${replace(replace(prefix, '.', '-'), '/', '-')}'
    properties: {
      addressPrefix: prefix
      nextHopType: 'VirtualNetworkGateway'
    }
  }
]
