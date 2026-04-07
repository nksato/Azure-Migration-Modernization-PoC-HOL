// ============================================================
// Spoke VNets x 4（パラメータ化）
// ============================================================

param location string
param tags object
param spoke1RgName string
param spoke2RgName string
param spoke3RgName string
param spoke4RgName string

// Spoke1 — Rehost
module spoke1 'spoke-vnet-single.bicep' = {
  name: 'deploy-vnet-spoke1'
  scope: resourceGroup(spoke1RgName)
  params: {
    location: location
    tags: tags
    vnetName: 'vnet-spoke1'
    vnetAddressPrefix: '10.20.0.0/16'
    subnets: [
      { name: 'snet-web', addressPrefix: '10.20.1.0/24' }
      { name: 'snet-db', addressPrefix: '10.20.2.0/24' }
    ]
  }
}

// Spoke2 — DB PaaS 化
module spoke2 'spoke-vnet-single.bicep' = {
  name: 'deploy-vnet-spoke2'
  scope: resourceGroup(spoke2RgName)
  params: {
    location: location
    tags: tags
    vnetName: 'vnet-spoke2'
    vnetAddressPrefix: '10.21.0.0/16'
    subnets: [
      { name: 'snet-web', addressPrefix: '10.21.1.0/24' }
      { name: 'snet-pep', addressPrefix: '10.21.2.0/24' }
    ]
  }
}

// Spoke3 — コンテナ化
module spoke3 'spoke-vnet-single.bicep' = {
  name: 'deploy-vnet-spoke3'
  scope: resourceGroup(spoke3RgName)
  params: {
    location: location
    tags: tags
    vnetName: 'vnet-spoke3'
    vnetAddressPrefix: '10.22.0.0/16'
    subnets: [
      { name: 'snet-aca', addressPrefix: '10.22.0.0/23' }
      { name: 'snet-pep', addressPrefix: '10.22.3.0/24' }
    ]
  }
}

// Spoke4 — フル PaaS
module spoke4 'spoke-vnet-single.bicep' = {
  name: 'deploy-vnet-spoke4'
  scope: resourceGroup(spoke4RgName)
  params: {
    location: location
    tags: tags
    vnetName: 'vnet-spoke4'
    vnetAddressPrefix: '10.23.0.0/16'
    subnets: [
      { name: 'snet-appservice', addressPrefix: '10.23.1.0/24' }
      { name: 'snet-pep', addressPrefix: '10.23.2.0/24' }
    ]
  }
}

output spoke1VnetId string = spoke1.outputs.vnetId
output spoke1VnetName string = spoke1.outputs.vnetName
output spoke2VnetId string = spoke2.outputs.vnetId
output spoke2VnetName string = spoke2.outputs.vnetName
output spoke3VnetId string = spoke3.outputs.vnetId
output spoke3VnetName string = spoke3.outputs.vnetName
output spoke4VnetId string = spoke4.outputs.vnetId
output spoke4VnetName string = spoke4.outputs.vnetName
