// Azure Portal Dashboard - PoC Environment Overview

@description('Azure region for deployment')
param location string

@description('Subscription ID for portal deep links')
param subscriptionId string

@description('Common tags')
param tags object

var portalBase = 'https://portal.azure.com/#@/resource/subscriptions/${subscriptionId}'

resource dashboard 'Microsoft.Portal/dashboards@2020-09-01-preview' = {
  name: 'dash-poc-overview'
  location: location
  tags: union(tags, { 'hidden-title': 'PoC Environment Overview' })
  properties: {
    lenses: [
      {
        order: 0
        parts: [
          {
            position: { x: 0, y: 0, colSpan: 12, rowSpan: 3 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '# Azure Migration & Modernization PoC\n\n```\nOn-Prem (10.0.0.0/16) ──VPN── Hub (10.10.0.0/16) ──Peering── Spoke1 (10.20.0.0/16) Rehost\n  Hyper-V Host (D8s_v5)         FW / Bastion / VPN GW           Spoke2 (10.21.0.0/16) DB PaaS\n  DC01 / WEB01 / SQL01          Log Analytics                   Spoke3 (10.22.0.0/16) Container\n  Migrate Appliance             Route Table                     Spoke4 (10.23.0.0/16) Full PaaS\n```'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 0, y: 3, colSpan: 6, rowSpan: 4 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Hub Resources (rg-hub)\n\n| Resource | Type |\n|----------|------|\n| [afw-hub](${portalBase}/resourceGroups/rg-hub/providers/Microsoft.Network/azureFirewalls/afw-hub/overview) | Firewall Basic |\n| [bas-hub](${portalBase}/resourceGroups/rg-hub/providers/Microsoft.Network/bastionHosts/bas-hub/overview) | Bastion Basic |\n| [vpngw-hub](${portalBase}/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworkGateways/vpngw-hub/overview) | VPN GW VpnGw1AZ |\n| [dnspr-hub](${portalBase}/resourceGroups/rg-hub/providers/Microsoft.Network/dnsResolvers/dnspr-hub/overview) | DNS Private Resolver |\n| [privatelink.database.windows.net](${portalBase}/resourceGroups/rg-hub/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net/overview) | Private DNS Zone |\n| [law-hub](${portalBase}/resourceGroups/rg-hub/providers/Microsoft.OperationalInsights/workspaces/law-hub/overview) | Log Analytics |\n| [rt-spokes-to-fw](${portalBase}/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-spokes-to-fw/overview) | Route Table |'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 6, y: 3, colSpan: 6, rowSpan: 4 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Network\n\n### Peering\n| Peering | State |\n|---------|-------|\n| Hub ↔ Spoke1 | Connected |\n| Hub ↔ Spoke2 | Connected |\n| Hub ↔ Spoke3 | Connected |\n| Hub ↔ Spoke4 | Connected |\n\n### Firewall Rules\n| Rule | Src → Dst | Ports |\n|------|----------|-------|\n| OnPrem→Spokes | 10.0.0.0/16 → 10.20-23.0.0/16 | Any |\n| Spokes→OnPrem | 10.20-23.0.0/16 → 10.0.0.0/16 | Any |\n| DNS Out | 10.0.0.0/8 → * | 53 |\n| HTTPS Out | 10.0.0.0/8 → * | 443 |\n| HTTP Out | 10.0.0.0/8 → * | 80 |'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 0, y: 7, colSpan: 3, rowSpan: 3 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Spoke1: Rehost\n[rg-spoke1](${portalBase}/resourceGroups/rg-spoke1/overview)\n\n- **VNet**: 10.20.0.0/16\n- snet-web / snet-db\n- **Target**: Azure VM x 2\n- **Tool**: Copilot Migration Agent'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 3, y: 7, colSpan: 3, rowSpan: 3 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Spoke2: DB PaaS\n[rg-spoke2](${portalBase}/resourceGroups/rg-spoke2/overview)\n\n- **VNet**: 10.21.0.0/16\n- snet-web / snet-pep\n- **Target**: VM + Azure SQL\n- **Tool**: Copilot App Mod + DMS'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 6, y: 7, colSpan: 3, rowSpan: 3 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Spoke3: Container\n[rg-spoke3](${portalBase}/resourceGroups/rg-spoke3/overview)\n\n- **VNet**: 10.22.0.0/16\n- snet-aca / snet-pep\n- **Target**: Container Apps + SQL\n- **Tool**: Copilot App Mod + Docker'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 9, y: 7, colSpan: 3, rowSpan: 3 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Spoke4: Full PaaS\n[rg-spoke4](${portalBase}/resourceGroups/rg-spoke4/overview)\n\n- **VNet**: 10.23.0.0/16\n- snet-appservice / snet-pep\n- **Target**: App Service + SQL\n- **Tool**: Copilot App Mod'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 0, y: 10, colSpan: 6, rowSpan: 3 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Azure Policy\n\n| Policy | Effect |\n|--------|--------|\n| Allowed locations (JE/JW) | Deny |\n| Require Environment tag on RG | Deny |\n| Storage public access | Audit |\n| SQL auditing enabled | Audit |\n| SQL public access | Audit |\n| Management ports closed | Audit |\n| App Service public access | Audit |'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          {
            position: { x: 6, y: 10, colSpan: 6, rowSpan: 3 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Route Table (rt-spokes-to-fw)\n\n| Route | Prefix | Next Hop |\n|-------|--------|----------|\n| default-to-firewall | 0.0.0.0/0 | FW Private IP |\n| onprem-to-firewall | 10.0.0.0/16 | FW Private IP |\n\n## Tags (All Resources)\n\n| Tag | Value |\n|-----|-------|\n| Environment | PoC |\n| SecurityControl | ignore |'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
          // Resource Graph: All PoC resources
          {
            position: { x: 0, y: 13, colSpan: 12, rowSpan: 4 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: '## Resource Groups\n\n| RG | Purpose | Link |\n|-----|---------|------|\n| rg-hub | Hub (FW/Bastion/VPN GW) | [Open](${portalBase}/resourceGroups/rg-hub/overview) |\n| rg-spoke1 | Spoke1: Rehost | [Open](${portalBase}/resourceGroups/rg-spoke1/overview) |\n| rg-spoke2 | Spoke2: DB PaaS | [Open](${portalBase}/resourceGroups/rg-spoke2/overview) |\n| rg-spoke3 | Spoke3: Container | [Open](${portalBase}/resourceGroups/rg-spoke3/overview) |\n| rg-spoke4 | Spoke4: Full PaaS | [Open](${portalBase}/resourceGroups/rg-spoke4/overview) |\n| rg-onprem | On-Prem (Hyper-V) | [Open](${portalBase}/resourceGroups/rg-onprem/overview) |\n\n[Resource Graph Explorer](https://portal.azure.com/#view/HubsExtension/ArgQueryBlade) - Run custom queries to check all resources'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                  }
                }
              }
            }
          }
        ]
      }
    ]
  }
}

output dashboardId string = dashboard.id
