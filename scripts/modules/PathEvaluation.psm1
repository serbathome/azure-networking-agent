Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'NsgEvaluation.psm1')

function Get-PropertyValue {
    param(
        [object] $InputObject,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-VirtualNetworkServicePrefixes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $LocalTopology,

        [Parameter(Mandatory)]
        [psobject] $RemoteTopology
    )

    $prefixes = [Collections.Generic.List[string]]::new()
    foreach ($prefix in @($LocalTopology.addressPrefixes)) {
        if (-not [string]::IsNullOrWhiteSpace([string] $prefix)) {
            $prefixes.Add([string] $prefix)
        }
    }

    if ([string]::Equals(
        [string] $LocalTopology.virtualNetworkId,
        [string] $RemoteTopology.virtualNetworkId,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        return @($prefixes | Sort-Object -Unique)
    }

    foreach ($peering in @($LocalTopology.peerings)) {
        $remoteVirtualNetwork = Get-PropertyValue -InputObject $peering -Name 'remoteVirtualNetwork'
        $remoteId = [string] (Get-PropertyValue -InputObject $remoteVirtualNetwork -Name 'id')
        $state = [string] (Get-PropertyValue -InputObject $peering -Name 'peeringState')
        $allowAccess = Get-PropertyValue -InputObject $peering -Name 'allowVirtualNetworkAccess'

        if ([string]::Equals($remoteId, [string] $RemoteTopology.virtualNetworkId, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($state, 'Connected', [StringComparison]::OrdinalIgnoreCase) -and
            $allowAccess -ne $false) {
            foreach ($prefix in @($RemoteTopology.addressPrefixes)) {
                if (-not [string]::IsNullOrWhiteSpace([string] $prefix)) {
                    $prefixes.Add([string] $prefix)
                }
            }
        }
    }

    return @($prefixes | Sort-Object -Unique)
}

function Get-RouteDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Routes,

        [Parameter(Mandatory)]
        [System.Net.IPAddress] $DestinationAddress
    )

    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($route in @($Routes)) {
        if ($null -eq $route -or
            -not [string]::Equals([string] $route.state, 'Active', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        foreach ($prefix in @($route.addressPrefix)) {
            $prefixText = [string] $prefix
            if (-not (Test-IpInCidr -Address $DestinationAddress -Cidr $prefixText)) {
                continue
            }

            $prefixLength = 0
            if ($prefixText -match '/(\d+)$') {
                $prefixLength = [int] $Matches[1]
            }

            $candidates.Add([pscustomobject] @{
                route = $route
                prefix = $prefixText
                prefixLength = $prefixLength
            })
        }
    }

    $selected = $candidates |
        Sort-Object -Property @{ Expression = 'prefixLength'; Descending = $true } |
        Select-Object -First 1

    if ($null -eq $selected) {
        return [pscustomobject] @{
            status = 'inconclusive'
            route = $null
            prefix = $null
            reason = "No active effective route matched destination '$DestinationAddress'."
        }
    }

    $nextHopType = [string] $selected.route.nextHopType
    if ([string]::Equals($nextHopType, 'None', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject] @{
            status = 'blocked'
            route = $selected.route
            prefix = $selected.prefix
            reason = "The selected route '$($selected.prefix)' has next hop type None."
        }
    }

    if ($nextHopType -in @('VirtualAppliance', 'Internet')) {
        return [pscustomobject] @{
            status = 'inconclusive'
            route = $selected.route
            prefix = $selected.prefix
            reason = "The selected route '$($selected.prefix)' uses next hop '$nextHopType', which requires another component check."
        }
    }

    return [pscustomobject] @{
        status = 'allowed'
        route = $selected.route
        prefix = $selected.prefix
        reason = "The selected route '$($selected.prefix)' uses next hop '$nextHopType'."
    }
}

function Get-FirstPathIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Stages
    )

    foreach ($stage in @($Stages)) {
        if ([string] $stage.status -in @('blocked', 'inconclusive')) {
            return $stage
        }
    }

    return $null
}

Export-ModuleMember -Function Get-VirtualNetworkServicePrefixes, Get-RouteDecision, Get-FirstPathIssue
