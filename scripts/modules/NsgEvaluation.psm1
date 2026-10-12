Set-StrictMode -Version Latest

function Get-RuleValues {
    param(
        [Parameter(Mandatory)]
        [psobject] $Rule,
        [Parameter(Mandatory)]
        [string] $PluralName,
        [Parameter(Mandatory)]
        [string] $SingularName
    )

    $plural = $Rule.PSObject.Properties[$PluralName]
    if ($null -ne $plural -and $null -ne $plural.Value -and @($plural.Value).Count -gt 0) {
        return @($plural.Value)
    }

    $singular = $Rule.PSObject.Properties[$SingularName]
    if ($null -ne $singular -and -not [string]::IsNullOrWhiteSpace([string] $singular.Value)) {
        return @($singular.Value)
    }

    return @()
}

function Test-IpInCidr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $Address,
        [Parameter(Mandatory)]
        [string] $Cidr
    )

    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) {
        return $false
    }

    $network = $null
    $prefixLength = 0
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref] $network) -or
        -not [int]::TryParse($parts[1], [ref] $prefixLength)) {
        return $false
    }

    $addressBytes = $Address.GetAddressBytes()
    $networkBytes = $network.GetAddressBytes()
    if ($addressBytes.Length -ne $networkBytes.Length -or
        $prefixLength -lt 0 -or
        $prefixLength -gt ($addressBytes.Length * 8)) {
        return $false
    }

    $wholeBytes = [Math]::Floor($prefixLength / 8)
    $remainingBits = $prefixLength % 8

    for ($index = 0; $index -lt $wholeBytes; $index++) {
        if ($addressBytes[$index] -ne $networkBytes[$index]) {
            return $false
        }
    }

    if ($remainingBits -gt 0) {
        $mask = (0xFF -shl (8 - $remainingBits)) -band 0xFF
        if (($addressBytes[$wholeBytes] -band $mask) -ne ($networkBytes[$wholeBytes] -band $mask)) {
            return $false
        }
    }

    return $true
}

function Get-AddressMatch {
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $Address,
        [object[]] $Prefixes,
        [string[]] $VirtualNetworkPrefixes = @()
    )

    $sawUnresolvedTag = $false
    foreach ($prefixValue in @($Prefixes)) {
        $prefix = [string] $prefixValue
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            continue
        }

        if ($prefix -in @('*', 'Any', '0.0.0.0/0', '::/0')) {
            return $true
        }

        if ([string]::Equals($prefix, 'VirtualNetwork', [StringComparison]::OrdinalIgnoreCase)) {
            if (@($VirtualNetworkPrefixes).Count -eq 0) {
                $sawUnresolvedTag = $true
                continue
            }

            foreach ($virtualNetworkPrefix in $VirtualNetworkPrefixes) {
                if (Test-IpInCidr -Address $Address -Cidr $virtualNetworkPrefix) {
                    return $true
                }
            }
            continue
        }

        $parsedAddress = $null
        if ([Net.IPAddress]::TryParse($prefix, [ref] $parsedAddress)) {
            if ($parsedAddress.Equals($Address)) {
                return $true
            }
            continue
        }

        if ($prefix.Contains('/')) {
            if (Test-IpInCidr -Address $Address -Cidr $prefix) {
                return $true
            }
            continue
        }

        $sawUnresolvedTag = $true
    }

    if ($sawUnresolvedTag) {
        return $null
    }

    return $false
}

function Get-PortMatch {
    param(
        [Nullable[int]] $Port,
        [object[]] $Ranges
    )

    foreach ($rangeValue in @($Ranges)) {
        $range = [string] $rangeValue
        if ($range -in @('*', 'Any')) {
            return $true
        }

        if ($null -eq $Port) {
            if ($range -eq '0-65535') {
                return $true
            }
            continue
        }

        $singlePort = 0
        if ([int]::TryParse($range, [ref] $singlePort)) {
            if ([int] $Port -eq $singlePort) {
                return $true
            }
            continue
        }

        if ($range -match '^(\d+)-(\d+)$') {
            if ([int] $Port -ge [int] $Matches[1] -and [int] $Port -le [int] $Matches[2]) {
                return $true
            }
        }
    }

    if ($null -eq $Port) {
        return $null
    }

    return $false
}

function Test-ProtocolMatch {
    param(
        [string] $RuleProtocol,
        [string] $Protocol
    )

    return $RuleProtocol -in @('*', 'Any', 'All') -or
        [string]::Equals($RuleProtocol, $Protocol, [StringComparison]::OrdinalIgnoreCase)
}

function Get-NsgRuleDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Rules,
        [Parameter(Mandatory)]
        [string] $Direction,
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $SourceAddress,
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $DestinationAddress,
        [Parameter(Mandatory)]
        [ValidateSet('Tcp', 'Udp', 'Icmp', 'Any')]
        [string] $Protocol,
        [Nullable[int]] $SourcePort,
        [Nullable[int]] $DestinationPort,
        [string[]] $VirtualNetworkPrefixes = @()
    )

    $unresolvedRule = $null
    foreach ($rule in @($Rules | Sort-Object { [int] $_.priority })) {
        if (-not [string]::Equals([string] $rule.direction, $Direction, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-ProtocolMatch -RuleProtocol ([string] $rule.protocol) -Protocol $Protocol)) {
            continue
        }

        $sourcePortMatch = Get-PortMatch -Port $SourcePort -Ranges (
            Get-RuleValues -Rule $rule -PluralName 'sourcePortRanges' -SingularName 'sourcePortRange'
        )
        $destinationPortMatch = Get-PortMatch -Port $DestinationPort -Ranges (
            Get-RuleValues -Rule $rule -PluralName 'destinationPortRanges' -SingularName 'destinationPortRange'
        )

        if ($sourcePortMatch -eq $false -or $destinationPortMatch -eq $false) {
            continue
        }

        $sourceAddressMatch = Get-AddressMatch -Address $SourceAddress -Prefixes (
            Get-RuleValues -Rule $rule -PluralName 'sourceAddressPrefixes' -SingularName 'sourceAddressPrefix'
        ) -VirtualNetworkPrefixes $VirtualNetworkPrefixes
        $destinationAddressMatch = Get-AddressMatch -Address $DestinationAddress -Prefixes (
            Get-RuleValues -Rule $rule -PluralName 'destinationAddressPrefixes' -SingularName 'destinationAddressPrefix'
        ) -VirtualNetworkPrefixes $VirtualNetworkPrefixes

        if ($sourceAddressMatch -eq $false -or $destinationAddressMatch -eq $false) {
            continue
        }

        if ($null -eq $sourcePortMatch -or $null -eq $sourceAddressMatch -or $null -eq $destinationAddressMatch) {
            if ($null -eq $unresolvedRule) {
                $unresolvedRule = $rule
            }
            continue
        }

        if ($null -ne $unresolvedRule) {
            return [pscustomobject] @{
                status = 'inconclusive'
                access = $null
                rule = $unresolvedRule
                reason = 'A higher-priority rule contains an unresolved service tag or source-port condition.'
            }
        }

        return [pscustomobject] @{
            status = 'matched'
            access = [string] $rule.access
            rule = $rule
            reason = 'The rule matched the supplied flow.'
        }
    }

    if ($null -ne $unresolvedRule) {
        return [pscustomobject] @{
            status = 'inconclusive'
            access = $null
            rule = $unresolvedRule
            reason = 'A potentially matching rule contains an unresolved service tag or source-port condition.'
        }
    }

    return [pscustomobject] @{
        status = 'inconclusive'
        access = $null
        rule = $null
        reason = 'No effective rule matched the supplied flow.'
    }
}

Export-ModuleMember -Function Test-IpInCidr, Get-NsgRuleDecision
