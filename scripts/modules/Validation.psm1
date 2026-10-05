Set-StrictMode -Version Latest

function Assert-IpAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $ParameterName
    )

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref] $address)) {
        throw "$ParameterName must be a valid IPv4 or IPv6 address."
    }

    return $address
}

function Assert-Port {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $Value,

        [string] $ParameterName = 'Port'
    )

    if ($Value -lt 1 -or $Value -gt 65535) {
        throw "$ParameterName must be between 1 and 65535."
    }

    return $Value
}

function ConvertTo-IncidentTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AllowWhiteSpaces,
        [ref] $parsed
    )) {
        throw 'IncidentTime must be a valid ISO-8601 timestamp with a time zone.'
    }

    if ($Value -notmatch '(Z|[+-]\d{2}:\d{2})$') {
        throw 'IncidentTime must include an explicit UTC offset or Z suffix.'
    }

    return $parsed.ToUniversalTime()
}

function Assert-SubscriptionId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $subscriptionGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref] $subscriptionGuid)) {
        throw "Subscription ID '$Value' is not a valid GUID."
    }

    return $subscriptionGuid.ToString()
}

function Assert-ResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/[^/]+/.+$') {
        throw 'ResourceId must be a complete Azure resource ID.'
    }

    return $Value
}

Export-ModuleMember -Function Assert-IpAddress, Assert-Port, ConvertTo-IncidentTime, Assert-SubscriptionId, Assert-ResourceId
