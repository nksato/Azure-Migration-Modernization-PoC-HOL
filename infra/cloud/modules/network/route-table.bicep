// ============================================================
// Route Tables (UDR) — 各 Spoke サブネット → Firewall
// ============================================================

param location string
param tags object
param firewallPrivateIp string
param spoke1RgName string
param spoke2RgName string
param spoke3RgName string
param spoke4RgName string

// Spoke 共通のルートテーブルを各 RG に作成
module rtSpoke1 'route-table-single.bicep' = {
  name: 'deploy-rt-spoke1'
  scope: resourceGroup(spoke1RgName)
  params: {
    location: location
    tags: tags
    routeTableName: 'rt-spoke1'
    firewallPrivateIp: firewallPrivateIp
  }
}

module rtSpoke2 'route-table-single.bicep' = {
  name: 'deploy-rt-spoke2'
  scope: resourceGroup(spoke2RgName)
  params: {
    location: location
    tags: tags
    routeTableName: 'rt-spoke2'
    firewallPrivateIp: firewallPrivateIp
  }
}

module rtSpoke3 'route-table-single.bicep' = {
  name: 'deploy-rt-spoke3'
  scope: resourceGroup(spoke3RgName)
  params: {
    location: location
    tags: tags
    routeTableName: 'rt-spoke3'
    firewallPrivateIp: firewallPrivateIp
  }
}

module rtSpoke4 'route-table-single.bicep' = {
  name: 'deploy-rt-spoke4'
  scope: resourceGroup(spoke4RgName)
  params: {
    location: location
    tags: tags
    routeTableName: 'rt-spoke4'
    firewallPrivateIp: firewallPrivateIp
  }
}
