using './vpn-deploy.bicep'

param sharedKey = readEnvironmentVariable('VPN_SHARED_KEY', '')
