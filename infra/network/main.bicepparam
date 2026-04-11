using './main.bicep'

param vpnSharedKey = readEnvironmentVariable('VPN_SHARED_KEY', '')

// Hub VPN Gateway: false = use existing (dual mode), true = create new (standalone)
// param createHubVpnGateway = true
