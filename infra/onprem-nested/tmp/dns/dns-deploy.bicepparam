using './dns-deploy.bicep'

// Hyper-V host private IP - check Azure portal or run:
//   az vm list-ip-addresses -g rg-onprem-nested -n vm-onprem-hv01 --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv
param onpremDnsForwarderIp = '<HYPER-V-HOST-IP>'

// Uncomment below to enable Cloud VM name resolution (azure.internal)
// param enableCloudVmResolution = true
// param spokeVnetLinks = [
//   { name: 'link-vnet-spoke1', vnetId: '/subscriptions/<SUB_ID>/resourceGroups/rg-spoke1/providers/Microsoft.Network/virtualNetworks/vnet-spoke1' }
//   { name: 'link-vnet-spoke2', vnetId: '/subscriptions/<SUB_ID>/resourceGroups/rg-spoke2/providers/Microsoft.Network/virtualNetworks/vnet-spoke2' }
//   { name: 'link-vnet-spoke3', vnetId: '/subscriptions/<SUB_ID>/resourceGroups/rg-spoke3/providers/Microsoft.Network/virtualNetworks/vnet-spoke3' }
//   { name: 'link-vnet-spoke4', vnetId: '/subscriptions/<SUB_ID>/resourceGroups/rg-spoke4/providers/Microsoft.Network/virtualNetworks/vnet-spoke4' }
// ]
