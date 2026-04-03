using 'main.bicep'

param location = 'japaneast'
param adminUsername = 'labadmin'
param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD', '')
param domainName = 'lab.local'
param vpnSharedKey = readEnvironmentVariable('VPN_SHARED_KEY', '')
param deployFirewall = true
param deployVpnGateway = true
param deployBastion = true
