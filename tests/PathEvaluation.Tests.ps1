$modulePath = Join-Path $PSScriptRoot '..\scripts\modules\PathEvaluation.psm1'
Import-Module $modulePath -Force

Describe 'Get-VirtualNetworkServicePrefixes' {
    It 'includes the shared VNet address space for endpoints in the same VNet' {
        $source = [pscustomobject] @{
            virtualNetworkId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet'
            addressPrefixes = @('10.0.0.0/16')
            peerings = @()
        }
        $destination = [pscustomobject] @{
            virtualNetworkId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet'
            addressPrefixes = @('10.0.0.0/16')
            peerings = @()
        }

        $prefixes = @(Get-VirtualNetworkServicePrefixes -LocalTopology $source -RemoteTopology $destination)

        $prefixes.Count | Should Be 1
        $prefixes[0] | Should Be '10.0.0.0/16'
    }

    It 'includes a connected peer address space when VNet access is allowed' {
        $remoteId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/remote'
        $source = [pscustomobject] @{
            virtualNetworkId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/local'
            addressPrefixes = @('10.0.0.0/16')
            peerings = @(
                [pscustomobject] @{
                    remoteVirtualNetwork = [pscustomobject] @{ id = $remoteId }
                    peeringState = 'Connected'
                    allowVirtualNetworkAccess = $true
                }
            )
        }
        $destination = [pscustomobject] @{
            virtualNetworkId = $remoteId
            addressPrefixes = @('10.1.0.0/16')
            peerings = @()
        }

        $prefixes = @(Get-VirtualNetworkServicePrefixes -LocalTopology $source -RemoteTopology $destination)

        $prefixes.Count | Should Be 2
        ($prefixes -contains '10.1.0.0/16') | Should Be $true
    }
}

Describe 'Get-RouteDecision' {
    BeforeAll {
        $routes = @(
            [pscustomobject] @{
                addressPrefix = @('0.0.0.0/0')
                nextHopType = 'Internet'
                nextHopIpAddress = @()
                state = 'Active'
            },
            [pscustomobject] @{
                addressPrefix = @('10.0.0.0/16')
                nextHopType = 'VnetLocal'
                nextHopIpAddress = @()
                state = 'Active'
            }
        )
    }

    It 'selects the longest matching active route' {
        $decision = Get-RouteDecision `
            -Routes $routes `
            -DestinationAddress ([Net.IPAddress]::Parse('10.0.1.6'))

        $decision.status | Should Be 'allowed'
        $decision.prefix | Should Be '10.0.0.0/16'
        $decision.route.nextHopType | Should Be 'VnetLocal'
    }

    It 'reports a None next hop as blocked' {
        $decision = Get-RouteDecision `
            -Routes @(
                [pscustomobject] @{
                    addressPrefix = @('10.0.1.0/24')
                    nextHopType = 'None'
                    nextHopIpAddress = @()
                    state = 'Active'
                }
            ) `
            -DestinationAddress ([Net.IPAddress]::Parse('10.0.1.6'))

        $decision.status | Should Be 'blocked'
    }

    It 'reports a virtual appliance as requiring another check' {
        $decision = Get-RouteDecision `
            -Routes @(
                [pscustomobject] @{
                    addressPrefix = @('10.0.1.0/24')
                    nextHopType = 'VirtualAppliance'
                    nextHopIpAddress = @('10.0.2.4')
                    state = 'Active'
                }
            ) `
            -DestinationAddress ([Net.IPAddress]::Parse('10.0.1.6'))

        $decision.status | Should Be 'inconclusive'
    }
}

Describe 'Get-FirstPathIssue' {
    It 'returns the first blocking or inconclusive stage in path order' {
        $stages = @(
            [pscustomobject] @{ name = 'source-outbound-nsg'; status = 'allowed' },
            [pscustomobject] @{ name = 'destination-inbound-nsg'; status = 'blocked' },
            [pscustomobject] @{ name = 'source-forward-route'; status = 'inconclusive' }
        )

        $issue = Get-FirstPathIssue -Stages $stages

        $issue.name | Should Be 'destination-inbound-nsg'
    }
}
