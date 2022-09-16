targetScope = 'subscription'

@description('Name of the resource group')
param resourceGroupName string = 'rg-enterprise-networking-spokes'

@description('The regional hub network to which this regional spoke will peer to.')
param hubVnetResourceId string

@description('The spokes\'s regional affinity, must be the same as the hub\'s location. All resources tied to this spoke will also be homed in this region. The network team maintains this approved regional list which is a subset of zones with Availability Zone support.')
@allowed([
  'australiaeast'
  'canadacentral'
  'centralus'
  'eastus'
  'eastus2'
  'westus2'
  'francecentral'
  'germanywestcentral'
  'northeurope'
  'southafricanorth'
  'southcentralus'
  'uksouth'
  'westeurope'
  'japaneast'
  'southeastasia'
])
param location string

@description('A /16 to contain the cluster')
@minLength(10)
@maxLength(18)
param clusterVnetAddressSpace string = '10.240.0.0/16'

@description('The resource ID of the Log Analytics Workspace in the hub')
param hubLaWorkspaceResourceId string

@description('The resource ID of the Firewall in the hub')
param hubFwResourceId string

@description('Domain name to use for App Gateway and AKS ingress.')
param domainName string

param appGatewayListenerCertificate string
param aksIngressControllerCertificate string

var orgAppId = 'BU0001A0008'
var clusterVNetName = 'vnet-spoke-${orgAppId}-00'
var routeTableName = 'route-to-${location}-hub-fw'
var nsgNodePoolsName = 'nsg-${clusterVNetName}-nodepools'
var nsgAksiLbName = 'nsg-${clusterVNetName}-aksilbs'
var nsgAppGwName = 'nsg-${clusterVNetName}-appgw'
var nsgPrivateLinkEndpointsSubnetName = 'nsg-${clusterVNetName}-privatelinkendpoints'
var hubNetworkName = split(hubVnetResourceId, '/')[8]
var toHubPeeringName = 'spoke-${orgAppId}-to-${hubNetworkName}'
var primaryClusterPipName = 'pip-${orgAppId}-00'

var subRgUniqueString = uniqueString('aks', subscription().subscriptionId, resourceGroupName, location)
var clusterName = 'aks-${subRgUniqueString}'
var logAnalyticsWorkspaceName = 'la-${clusterName}'
var keyVaultName = 'kv-${clusterName}'

var clusterNodesSubnetName = 'snet-clusternodes'
var vnetNodePoolSubnetResourceId = '${clusterVNet.outputs.resourceId}/subnets/${clusterNodesSubnetName}'

var akvPrivateDnsZonesName = 'privatelink.vaultcore.azure.net'
var aksIngressDomainName = 'aks-ingress.${domainName}'
var aksBackendDomainName = 'bu0001a0008-00.${aksIngressDomainName}'

var agwName = 'apw-${clusterName}'

module rg '../CARML/Microsoft.Resources/resourceGroups/deploy.bicep' = {
  name: resourceGroupName
  params: {
    name: resourceGroupName
    location: location
  }
}

module clusterLa '../CARML/Microsoft.OperationalInsights/workspaces/deploy.bicep' = {
  name: logAnalyticsWorkspaceName
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    serviceTier: 'PerGB2018'
    dataRetention: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    // savedSearches: [
    //   {
    //     name: 'AllPrometheus'
    //     category: 'Prometheus'
    //     displayName: 'All collected Prometheus information'
    //     query: 'InsightsMetrics | where Namespace == \'prometheus\''
    //   }
    //   {
    //     name: 'NodeRebootRequested'
    //     category: 'Prometheus'
    //     displayName: 'Nodes reboot required by kured'
    //     query: 'InsightsMetrics | where Namespace == \'prometheus\' and Name == \'kured_reboot_required\' | where Val > 0'
    //   }
    // ]
    gallerySolutions: [
      // {
      //   name: 'ContainerInsights'
      //   product: 'OMSGallery'
      //   publisher: 'Microsoft'
      // }
      {
        name: 'KeyVaultAnalytics'
        product: 'OMSGallery'
        publisher: 'Microsoft'
      }
    ]
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module keyVault '../CARML/Microsoft.KeyVault/vaults/deploy.bicep' = {
  name: keyVaultName
  params: {
    name: keyVaultName
    location: location
    accessPolicies: []
    vaultSku: 'standard'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    enableRbacAuthorization: true
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: true
    enableSoftDelete: true
    diagnosticWorkspaceId: clusterLa.outputs.resourceId
    secrets: {}
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'Key Vault Certificates Officer'
        principalIds: [
          mi_appgateway_frontend.outputs.principalId
          podmi_ingress_controller.outputs.principalId
        ]
      }
      {
        roleDefinitionIdOrName: 'Key Vault Secrets User'
        principalIds: [
          mi_appgateway_frontend.outputs.principalId
          podmi_ingress_controller.outputs.principalId
        ]
      }
      {
        roleDefinitionIdOrName: 'Key Vault Reader'
        principalIds: [
          mi_appgateway_frontend.outputs.principalId
          podmi_ingress_controller.outputs.principalId
        ]
      }
    ]
    privateEndpoints: [
      {
        name: 'nodepools-to-akv'
        subnetResourceId: vnetNodePoolSubnetResourceId
        service: 'vault'
        privateDnsZoneGroup: {
          privateDNSResourceIds: [
            akvPrivateDnsZones.outputs.resourceId
          ]
        }
      }
    ]
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
    mi_appgateway_frontend
    podmi_ingress_controller
  ]
}

module routeTable '../CARML/Microsoft.Network/routeTables/deploy.bicep' = {
  name: routeTableName
  params: {
    name: routeTableName
    location: location
    routes: [
      {
        name: 'r-nexthop-to-fw'
        properties: {
          nextHopType: 'VirtualAppliance'
          addressPrefix: '0.0.0.0/0'
          nextHopIpAddress: reference(hubFwResourceId, '2020-05-01').ipConfigurations[0].properties.privateIpAddress
        }
      }
    ]
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module nsgNodePools '../CARML/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  name: nsgNodePoolsName
  params: {
    name: nsgNodePoolsName
    location: location
    securityRules: []
    diagnosticWorkspaceId: hubLaWorkspaceResourceId
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module nsgAksiLb '../CARML/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  name: nsgAksiLbName
  params: {
    name: nsgAksiLbName
    location: location
    securityRules: []
    diagnosticWorkspaceId: hubLaWorkspaceResourceId
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module nsgAppGw '../CARML/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  name: nsgAppGwName
  params: {
    name: nsgAppGwName
    location: location
    securityRules: [
      {
        name: 'Allow443InBound'
        properties: {
          description: 'Allow ALL web traffic into 443. (If you wanted to allow-list specific IPs, this is where you\'d list them.)'
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationPortRange: '443'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowControlPlaneInBound'
        properties: {
          description: 'Allow Azure Control Plane in. (https://docs.microsoft.com/azure/application-gateway/configuration-infrastructure#network-security-groups)'
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '65200-65535'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowHealthProbesInBound'
        properties: {
          description: 'Allow Azure Health Probes in. (https://docs.microsoft.com/azure/application-gateway/configuration-infrastructure#network-security-groups)'
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationPortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowAllOutBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
    diagnosticWorkspaceId: hubLaWorkspaceResourceId
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module nsgPrivateLinkEndpointsSubnet '../CARML/Microsoft.Network/networkSecurityGroups/deploy.bicep' = {
  name: nsgPrivateLinkEndpointsSubnetName
  params: {
    name: nsgPrivateLinkEndpointsSubnetName
    location: location
    securityRules: [
      {
        name: 'AllowAll443InFromVnet'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
    diagnosticWorkspaceId: hubLaWorkspaceResourceId
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module clusterVNet '../CARML/Microsoft.Network/virtualNetworks/deploy.bicep' = {
  name: clusterVNetName
  params: {
    name: clusterVNetName
    location: location
    addressPrefixes: array(clusterVnetAddressSpace)
    diagnosticWorkspaceId: hubLaWorkspaceResourceId
    subnets: [
      {
        name: 'snet-clusternodes'
        addressPrefix: '10.240.0.0/22'
        routeTableId: routeTable.outputs.resourceId
        networkSecurityGroupId: nsgNodePools.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
      {
        name: 'snet-clusteringressservices'
        addressPrefix: '10.240.4.0/28'
        routeTableId: routeTable.outputs.resourceId
        networkSecurityGroupId: nsgAksiLb.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Disabled'
      }
      {
        name: 'snet-applicationgateway'
        addressPrefix: '10.240.4.16/28'
        networkSecurityGroupId: nsgAppGw.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Disabled'
      }
      {
        name: 'snet-privatelinkendpoints'
        addressPrefix: '10.240.4.32/28'
        networkSecurityGroupId: nsgPrivateLinkEndpointsSubnet.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
    ]
    virtualNetworkPeerings: [
      {
        remoteVirtualNetworkId: hubVnetResourceId
        remotePeeringName: toHubPeeringName
        allowForwardedTraffic: true
        allowVirtualNetworkAccess: true
        allowGatewayTransit: false
        remotePeeringEnabled: true
        useRemoteGateways: false
      }
    ]
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module primaryClusterPip '../CARML/Microsoft.Network/publicIPAddresses/deploy.bicep' = {
  name: primaryClusterPipName
  params: {
    name: primaryClusterPipName
    location: location
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    zones: [
      '1'
      '2'
      '3'
    ]
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}


// module akvCertFrontend './cert.bicep' = {
//   name: 'CreateFeKvCert'
//   params: {
//     location: location
//     akvName: keyVault.name
//     certificateNameFE: 'frontendCertificate'
//     certificateCommonNameFE: 'bicycle.${domainName}'
//     certificateNameBE: 'backendCertificate'
//     certificateCommonNameBE: '*.aks-ingress.${domainName}'
//   }
//   scope: resourceGroup(resourceGroupName)
// }

module mi_appgateway_frontend '../CARML/Microsoft.ManagedIdentity/userAssignedIdentities/deploy.bicep' = {
  name: 'mi-appgateway-frontend'
  params: {
    name: 'mi-appgateway-frontend'
    location: location
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module podmi_ingress_controller '../CARML/Microsoft.ManagedIdentity/userAssignedIdentities/deploy.bicep' = {
  name: 'podmi-ingress-controller'
  params: {
    name: 'podmi-ingress-controller'
    location: location
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module akvPrivateDnsZones '../CARML/Microsoft.Network/privateDnsZones/deploy.bicep' = {
  name: akvPrivateDnsZonesName
  params: {
    name: akvPrivateDnsZonesName
    location: 'global'
    virtualNetworkLinks: [
      {
        name: 'to_${clusterVNetName}'
        virtualNetworkResourceId: clusterVNet.outputs.resourceId
        registrationEnabled: false
      }
    ]
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module aksIngressDomain '../CARML/Microsoft.Network/privateDnsZones/deploy.bicep' = {
  name: aksIngressDomainName
  params: {
    name: aksIngressDomainName
    a: [
      {
        name: 'bu0001a0008-00'
        ttl: 3600
        aRecords: [
          {
            ipv4Address: '10.240.4.4'
          }
        ]
      }
    ]
    location: 'global'
    virtualNetworkLinks: [
      {
        name: 'to_${clusterVNetName}'
        virtualNetworkResourceId: clusterVNet.outputs.resourceId
        registrationEnabled: false
      }
    ]
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
}

module frontendCert '../CARML/Microsoft.KeyVault/vaults/secrets/deploy.bicep' = {
  name: 'frontendCert'
  params: {
    value: appGatewayListenerCertificate
    keyVaultName: keyVaultName
    name: 'frontendCert'
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
    keyVault
  ]
}

module backendCert '../CARML/Microsoft.KeyVault/vaults/secrets/deploy.bicep' = {
  name: 'backendCert'
  params: {
    value: aksIngressControllerCertificate
    keyVaultName: keyVaultName
    name: 'backendCert'
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
    keyVault
  ]
}

module wafPolicy '../CARML/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/deploy.bicep' = {
  name: 'waf-${clusterName}'
  params: {
    location: location
    name:'waf-${clusterName}'
    policySettings: {
      fileUploadLimitInMb: 10
      state: 'Enabled'
      mode: 'Prevention'
    }
    managedRules: {
      managedRuleSets: [
        {
            ruleSetType: 'OWASP'
            ruleSetVersion: '3.2'
            ruleGroupOverrides: []
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '0.1'
          ruleGroupOverrides: []
        }
      ]
    }
  }
  scope: resourceGroup(resourceGroupName)
}

module agw '../CARML/Microsoft.Network/applicationGateways/deploy.bicep' = {
  name: agwName
  params: {
    name: agwName
    location: location
    firewallPolicyId: wafPolicy.outputs.resourceId
    userAssignedIdentities: {
      '${mi_appgateway_frontend.outputs.resourceId}': {}
    }
    sku: 'WAF_v2'
    trustedRootCertificates: [
      {
        name: 'root-cert-wildcard-aks-ingress'
        properties: {
          keyVaultSecretId: '${keyVault.outputs.uri}secrets/${backendCert.outputs.name}'
        }
      }
    ]
    gatewayIPConfigurations: [
      {
        name: 'apw-ip-configuration'
        properties: {
          subnet: {
            id: '${clusterVNet.outputs.resourceId}/subnets/snet-applicationgateway'
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'apw-frontend-ip-configuration'
        properties: {
          publicIPAddress: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/publicIpAddresses/pip-BU0001A0008-00'
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-443'
        properties: {
          port: 443
        }
      }
    ]
    autoscaleMinCapacity: 0
    autoscaleMaxCapacity: 10
    webApplicationFirewallConfiguration: {
      enabled: true
      firewallMode: 'Prevention'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.2'
      exclusions: []
      fileUploadLimitInMb: 10
      disabledRuleGroups: []
    }
    enableHttp2: false
    sslCertificates: [
      {
        name: '${agwName}-ssl-certificate'
        properties: {
          keyVaultSecretId: '${keyVault.outputs.uri}secrets/${frontendCert.outputs.name}'
        }
      }
    ]
    probes: [
      {
        name: 'probe-${aksBackendDomainName}'
        properties: {
          protocol: 'Https'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          minServers: 0
          match: {}
        }
      }
    ]
    backendAddressPools: [
      {
        name: aksBackendDomainName
        properties: {
          backendAddresses: [
            {
              fqdn: aksBackendDomainName
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'aks-ingress-backendpool-httpssettings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 20
          probe: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/probes/probe-${aksBackendDomainName}'
          }
          trustedRootCertificates: [
            {
              id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/trustedRootCertificates/root-cert-wildcard-aks-ingress'
            }
          ]
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-https'
        properties: {
          frontendIPConfiguration: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/frontendIPConfigurations/apw-frontend-ip-configuration'
          }
          frontendPort: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/frontendPorts/port-443'
          }
          protocol: 'Https'
          sslCertificate: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/sslCertificates/${agwName}-ssl-certificate'
          }
          hostName: 'bicycle.${domainName}'
          hostNames: []
          requireServerNameIndication: false
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'apw-routing-rules'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/httpListeners/listener-https'
          }
          backendAddressPool: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/backendAddressPools/${aksBackendDomainName}'
          }
          backendHttpSettings: {
            id: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/applicationGateways/${agwName}/backendHttpSettingsCollection/aks-ingress-backendpool-httpssettings'
          }
        }
      }
    ]
    zones: pickZones('Microsoft.Network', 'applicationGateways', location, 3)
    diagnosticWorkspaceId: clusterLa.outputs.resourceId
  }
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
    frontendCert
    backendCert
    keyVault
    wafPolicy
  ]
}

output clusterVnetResourceId string = clusterVNet.outputs.resourceId
output nodepoolSubnetResourceIds array = clusterVNet.outputs.subnetResourceIds
output aksIngressControllerPodManagedIdentityResourceId string = podmi_ingress_controller.outputs.resourceId
output keyVaultName string = keyVaultName
