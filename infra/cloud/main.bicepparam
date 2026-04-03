using 'main.bicep'

param location = 'japaneast'
param adminUsername = 'azureadmin'
param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD', '')
param domainName = 'contoso.local'
param deployFirewall = true
param deployVpnGateway = true
param deployBastion = true
