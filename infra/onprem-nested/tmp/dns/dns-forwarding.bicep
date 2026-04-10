// ============================================================================
// DNS Forwarding Module
// - Add forwarding ruleset to existing Hub DNS Resolver
// - Rule: contoso.local → Hyper-V host (DNS forwarder via VPN)
// - Link ruleset to Hub VNet
// ============================================================================

param location string
param dnsResolverName string = 'dnspr-hub'
param hubVnetName string = 'vnet-hub'
param onpremDnsForwarderIp string

resource dnsResolver 'Microsoft.Network/dnsResolvers@2022-07-01' existing = {
  name: dnsResolverName
}

resource outboundEndpoint 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' existing = {
  parent: dnsResolver
  name: 'outbound'
}

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
}

// --- Forwarding Ruleset ---
resource forwardingRuleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: 'frs-onprem'
  location: location
  properties: {
    dnsResolverOutboundEndpoints: [
      {
        id: outboundEndpoint.id
      }
    ]
  }
}

// --- Rule: contoso.local → Hyper-V host ---
resource ruleContoso 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = {
  parent: forwardingRuleset
  name: 'contoso-local'
  properties: {
    domainName: 'contoso.local.'
    targetDnsServers: [
      {
        ipAddress: onpremDnsForwarderIp
        port: 53
      }
    ]
  }
}

// --- Link ruleset to Hub VNet ---
resource vnetLink 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = {
  parent: forwardingRuleset
  name: 'link-hub-vnet'
  properties: {
    virtualNetwork: {
      id: hubVnet.id
    }
  }
}

output forwardingRulesetId string = forwardingRuleset.id
