// ============================================================
// DNS Forwarding Ruleset
// lab.local をオンプレ DC01 (10.0.1.4) へ転送
// Hub VNet にリンクしてクラウド側からオンプレ DNS を解決可能にする
// ============================================================

param location string
param tags object
param dnsResolverName string
param hubVnetId string

// 既存の DNS Private Resolver のアウトバウンドエンドポイントを参照
resource dnsResolverOutbound 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' existing = {
  name: '${dnsResolverName}/outbound'
}

// DNS 転送ルールセット
resource dnsForwardingRuleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: 'dnsrs-hub'
  location: location
  tags: tags
  properties: {
    dnsResolverOutboundEndpoints: [
      {
        id: dnsResolverOutbound.id
      }
    ]
  }
}

// 転送ルール: lab.local → DC01 (10.0.1.4)
resource forwardingRuleLabLocal 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = {
  parent: dnsForwardingRuleset
  name: 'rule-lab-local'
  properties: {
    domainName: 'lab.local.'
    forwardingRuleState: 'Enabled'
    targetDnsServers: [
      {
        ipAddress: '10.0.1.4'
        port: 53
      }
    ]
  }
}

// ルールセットを Hub VNet にリンク
resource rulesetLinkHub 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = {
  parent: dnsForwardingRuleset
  name: 'link-vnet-hub'
  properties: {
    virtualNetwork: {
      id: hubVnetId
    }
  }
}
