// ============================================================================
// DNS Deploy - Bidirectional DNS for On-prem <-> Cloud
//
// Architecture:
//   Cloud → contoso.local:
//     Spoke VM → Hub DNS Resolver (Outbound) → VPN → Hyper-V Host (10.0.1.x:53)
//       → vm-ad01 (192.168.100.10) → contoso.local A records
//
//   On-prem → privatelink.*:
//     vm-app01 → vm-ad01 (DNS) → Conditional Forwarder → VPN
//       → Hub DNS Resolver (Inbound) → Private DNS Zone
//
//   On-prem → azure.internal (optional):
//     vm-app01 → vm-ad01 (DNS) → Conditional Forwarder → VPN
//       → Hub DNS Resolver (Inbound) → Private DNS Zone (azure.internal)
//
// Prerequisites:
//   1. On-premises environment deployed (main.bicep)
//   2. VPN connection established (vpn-deploy.bicep)
//   3. Cloud environment deployed (Azure-Migration-Modernization-PoC-HOL)
//
// Deployment:
//   az deployment sub create -l japaneast -f dns-deploy.bicep -p dns-deploy.bicepparam
//
// After deployment, run on Hyper-V host via Bastion:
//   .\scripts\Configure-Dns.ps1 -HubDnsResolverInboundIp <IP>
//   .\scripts\Configure-Dns.ps1 -HubDnsResolverInboundIp <IP> -EnableCloudVmResolution
// ============================================================================

targetScope = 'subscription'

@description('Deployment region')
param location string = deployment().location

@description('Hub resource group name')
param hubResourceGroupName string = 'rg-hub'

@description('Hyper-V host private IP (DNS forwarder for contoso.local)')
param onpremDnsForwarderIp string

@description('Deploy azure.internal Private DNS Zone for Cloud VM name resolution')
param enableCloudVmResolution bool = false

@description('Spoke VNet links for azure.internal auto-registration (required when enableCloudVmResolution=true)')
param spokeVnetLinks array = []

// ============================================================================
// Existing Resource Group
// ============================================================================

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: hubResourceGroupName
}

// ============================================================================
// DNS Forwarding Ruleset (Hub → On-prem via VPN)
// ============================================================================

module dnsForwarding 'modules/dns-forwarding.bicep' = {
  scope: rgHub
  name: 'deploy-dns-forwarding'
  params: {
    location: location
    onpremDnsForwarderIp: onpremDnsForwarderIp
  }
}

// ============================================================================
// Cloud VM DNS Zone (Optional - azure.internal)
// ============================================================================

module cloudVmDns 'modules/dns-cloud-vm.bicep' = if (enableCloudVmResolution) {
  scope: rgHub
  name: 'deploy-dns-cloud-vm'
  params: {
    spokeVnetLinks: spokeVnetLinks
  }
}

// ============================================================================
// Outputs
// ============================================================================

output forwardingRulesetId string = dnsForwarding.outputs.forwardingRulesetId
