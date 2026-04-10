using './vpn-deploy.bicep'

param sharedKey = readEnvironmentVariable('VPN_SHARED_KEY', '')

// Hub VPN Gateway: false = use existing (dual mode), true = create new (standalone)
// param createHubVpnGateway = true
