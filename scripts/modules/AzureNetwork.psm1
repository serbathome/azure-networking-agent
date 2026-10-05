Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AzureCli.psm1')

function Find-AzureNetworkInterfaceByPrivateIp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $PrivateIpAddress,

        [string[]] $SubscriptionIds
    )

    $query = @"
resources
| where type =~ 'microsoft.network/networkinterfaces'
| mv-expand ipConfiguration = properties.ipConfigurations
| where tostring(ipConfiguration.properties.privateIPAddress) == '$($PrivateIpAddress.ToString())'
| project id, name, resourceGroup, subscriptionId, ipConfiguration,
          virtualMachine = properties.virtualMachine
"@
    $arguments = @(
        'graph', 'query',
        '--graph-query', $query,
        '--first', '1000',
        '--allow-partial-scopes'
    )
    $specifiedSubscriptionIds = @(
        $SubscriptionIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($specifiedSubscriptionIds.Count -gt 0) {
        $arguments += @('--subscriptions') + $specifiedSubscriptionIds
    }

    $response = Invoke-AzureCliJson -Arguments $arguments -TimeoutSeconds 120
    $matches = if ($null -ne $response -and $null -ne $response.data) {
        @($response.data)
    }
    else {
        @()
    }

    if ($matches.Count -gt 1) {
        $ids = @($matches | ForEach-Object { $_.id }) -join ', '
        throw "Source IP '$PrivateIpAddress' matched multiple network interfaces: $ids"
    }

    $match = if ($matches.Count -eq 1) {
        [pscustomobject] @{
            subscriptionId = [string] $matches[0].subscriptionId
            networkInterface = [pscustomobject] @{
                id = [string] $matches[0].id
                name = [string] $matches[0].name
                resourceGroup = [string] $matches[0].resourceGroup
            }
            ipConfiguration = $matches[0].ipConfiguration
            virtualMachine = $matches[0].virtualMachine
        }
    }
    else {
        $null
    }

    return [pscustomobject] @{
        match = $match
        skippedSubscriptions = @()
        searchedSubscriptionCount = $specifiedSubscriptionIds.Count
    }
}

function Get-NetworkTopology {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $NetworkInterfaceMatch
    )

    $subnetId = [string] $NetworkInterfaceMatch.ipConfiguration.properties.subnet.id
    if ($subnetId -notmatch '^(?<vnetId>.+/virtualNetworks/[^/]+)/subnets/(?<subnetName>[^/]+)$') {
        throw "NIC '$($NetworkInterfaceMatch.networkInterface.id)' has an invalid or missing subnet resource ID."
    }

    $virtualNetworkId = $Matches.vnetId
    $subnetName = $Matches.subnetName
    $virtualNetwork = Invoke-AzureCliJson -Arguments @(
        'network', 'vnet', 'show',
        '--ids', $virtualNetworkId,
        '--subscription', [string] $NetworkInterfaceMatch.subscriptionId
    ) -TimeoutSeconds 120

    $subnet = @($virtualNetwork.subnets) |
        Where-Object { [string]::Equals([string] $_.name, $subnetName, [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1

    if ($null -eq $subnet) {
        throw "Subnet '$subnetName' was not returned for virtual network '$virtualNetworkId'."
    }

    $subnetPrefixes = @()
    if ($null -ne $subnet.PSObject.Properties['addressPrefixes'] -and $null -ne $subnet.addressPrefixes) {
        $subnetPrefixes = @($subnet.addressPrefixes)
    }
    elseif ($null -ne $subnet.PSObject.Properties['addressPrefix']) {
        $subnetPrefixes = @($subnet.addressPrefix)
    }

    $virtualMachineId = $null
    if ($null -ne $NetworkInterfaceMatch.PSObject.Properties['virtualMachine'] -and
        $null -ne $NetworkInterfaceMatch.virtualMachine -and
        $null -ne $NetworkInterfaceMatch.virtualMachine.PSObject.Properties['id']) {
        $virtualMachineId = [string] $NetworkInterfaceMatch.virtualMachine.id
    }

    return [pscustomobject] @{
        subscriptionId = [string] $NetworkInterfaceMatch.subscriptionId
        networkInterfaceId = [string] $NetworkInterfaceMatch.networkInterface.id
        networkInterfaceName = [string] $NetworkInterfaceMatch.networkInterface.name
        virtualMachineId = $virtualMachineId
        subnetId = $subnetId
        subnetName = $subnetName
        subnetPrefixes = $subnetPrefixes
        virtualNetworkId = $virtualNetworkId
        virtualNetworkName = [string] $virtualNetwork.name
        addressPrefixes = @($virtualNetwork.addressSpace.addressPrefixes)
        peerings = @($virtualNetwork.virtualNetworkPeerings)
    }
}

function Get-EffectiveNsgRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $NetworkInterfaceMatch
    )

    $networkInterface = $NetworkInterfaceMatch.networkInterface
    $response = Invoke-AzureCliJson -Arguments @(
        'network', 'nic', 'list-effective-nsg',
        '--subscription', [string] $NetworkInterfaceMatch.subscriptionId,
        '--resource-group', [string] $networkInterface.resourceGroup,
        '--name', [string] $networkInterface.name
    ) -TimeoutSeconds 120

    $valueProperty = if ($null -ne $response) { $response.PSObject.Properties['value'] } else { $null }
    $groups = if ($null -ne $valueProperty -and $null -ne $valueProperty.Value) {
        @($valueProperty.Value)
    }
    else {
        @($response)
    }

    $rules = [Collections.Generic.List[object]]::new()
    foreach ($group in $groups) {
        $networkSecurityGroupProperty = $group.PSObject.Properties['networkSecurityGroup']
        $networkSecurityGroupId = if ($null -ne $networkSecurityGroupProperty -and
            $null -ne $networkSecurityGroupProperty.Value -and
            $null -ne $networkSecurityGroupProperty.Value.PSObject.Properties['id']) {
            [string] $networkSecurityGroupProperty.Value.PSObject.Properties['id'].Value
        }
        else {
            $null
        }

        foreach ($rule in @($group.effectiveSecurityRules)) {
            if ($null -eq $rule) {
                continue
            }

            $copy = [ordered] @{}
            foreach ($property in $rule.PSObject.Properties) {
                $copy[$property.Name] = $property.Value
            }
            $copy.networkSecurityGroupId = $networkSecurityGroupId
            $rules.Add([pscustomobject] $copy)
        }
    }

    return @($rules)
}

function Get-EffectiveRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $NetworkInterfaceMatch
    )

    $networkInterface = $NetworkInterfaceMatch.networkInterface
    $response = Invoke-AzureCliJson -Arguments @(
        'network', 'nic', 'show-effective-route-table',
        '--subscription', [string] $NetworkInterfaceMatch.subscriptionId,
        '--resource-group', [string] $networkInterface.resourceGroup,
        '--name', [string] $networkInterface.name
    ) -TimeoutSeconds 120

    $valueProperty = if ($null -ne $response) { $response.PSObject.Properties['value'] } else { $null }
    if ($null -ne $valueProperty -and $null -ne $valueProperty.Value) {
        return @($valueProperty.Value)
    }

    return @($response)
}

Export-ModuleMember -Function Find-AzureNetworkInterfaceByPrivateIp, Get-NetworkTopology, Get-EffectiveNsgRules, Get-EffectiveRoutes
