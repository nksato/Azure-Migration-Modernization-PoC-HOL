// ============================================================
// Route Table 単体 — route-table.bicep から呼び出し
// ============================================================

param location string
param tags object
param routeTableName string
param firewallPrivateIp string

resource rt 'Microsoft.Network/routeTables@2024-01-01' = {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

output routeTableId string = rt.id
