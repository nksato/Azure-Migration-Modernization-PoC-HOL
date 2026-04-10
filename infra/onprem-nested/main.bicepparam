using './main.bicep'

param prefix = 'onprem'
param adminUsername = 'labadmin'
param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD', '')
param vmSize = 'Standard_E8s_v5'
param dataDiskSizeGB = 256
