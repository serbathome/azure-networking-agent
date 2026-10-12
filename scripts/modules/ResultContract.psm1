Set-StrictMode -Version Latest

function New-Evidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Source,

        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $Observation,

        [DateTimeOffset] $ObservedAt = [DateTimeOffset]::UtcNow,

        [Collections.IDictionary] $Details
    )

    $evidence = [ordered] @{
        source = $Source
        resourceId = $ResourceId
        observation = $Observation
        observedAt = $ObservedAt.ToUniversalTime().ToString('o')
    }
    if ($null -ne $Details) {
        $evidence.details = [pscustomobject] $Details
    }

    return [pscustomobject] $evidence
}

function New-ToolResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Tool,

        [Parameter(Mandatory)]
        [ValidateSet('finding', 'no-finding', 'inconclusive', 'error')]
        [string] $Status,

        [Parameter(Mandatory)]
        [string] $Summary,

        [Parameter(Mandatory)]
        [ValidateSet('high', 'medium', 'low', 'none')]
        [string] $Confidence,

        [ValidateSet('current', 'reconstructed-at-incident-time', 'not-applicable')]
        [string] $ConfigurationBasis = 'not-applicable',

        [object[]] $Evidence = @(),

        [string[]] $Limitations = @(),

        [ValidateRange(0, [int]::MaxValue)]
        [int] $DurationMs = 0,

        [string] $ErrorCategory
    )

    $result = [ordered] @{
        schemaVersion = '1.0'
        tool = $Tool
        status = $Status
        summary = $Summary
        confidence = $Confidence
        configurationBasis = $ConfigurationBasis
        evidence = @($Evidence)
        limitations = @($Limitations)
        durationMs = $DurationMs
    }

    if (-not [string]::IsNullOrWhiteSpace($ErrorCategory)) {
        $result.errorCategory = $ErrorCategory
    }

    return [pscustomobject] $result
}

function Write-ToolResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject] $Result
    )

    process {
        $Result | ConvertTo-Json -Depth 12 -Compress
    }
}

Export-ModuleMember -Function New-Evidence, New-ToolResult, Write-ToolResult
