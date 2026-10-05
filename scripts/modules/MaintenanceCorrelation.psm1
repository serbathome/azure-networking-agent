Set-StrictMode -Version Latest

function Test-StringCollectionContains {
    [CmdletBinding()]
    param(
        [object[]] $Values,
        [string] $Expected
    )

    if ([string]::IsNullOrWhiteSpace($Expected)) {
        return $false
    }

    foreach ($value in @($Values)) {
        $candidate = [string] $value
        if ([string]::Equals($candidate, $Expected, [StringComparison]::OrdinalIgnoreCase) -or
            $Expected.StartsWith($candidate.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Find-MaintenanceEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Events,

        [Parameter(Mandatory)]
        [DateTimeOffset] $IncidentTime,

        [ValidateRange(0, 1440)]
        [int] $WindowMinutes = 15,

        [string] $ResourceId,

        [string] $CircuitId
    )

    $windowStart = $IncidentTime.ToUniversalTime().AddMinutes(-$WindowMinutes)
    $windowEnd = $IncidentTime.ToUniversalTime().AddMinutes($WindowMinutes)
    $matches = [Collections.Generic.List[object]]::new()

    foreach ($event in @($Events)) {
        if ($null -eq $event) {
            continue
        }

        $startTime = [DateTimeOffset]::MinValue
        $endTime = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse(
            [string] $event.startTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref] $startTime
        )) {
            continue
        }

        if (-not [DateTimeOffset]::TryParse(
            [string] $event.endTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref] $endTime
        )) {
            $endTime = $startTime
        }

        if ($endTime -lt $windowStart -or $startTime -gt $windowEnd) {
            continue
        }

        if ([string]::Equals([string] $event.status, 'cancelled', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $hasHint = -not [string]::IsNullOrWhiteSpace($ResourceId) -or
            -not [string]::IsNullOrWhiteSpace($CircuitId)
        $resourceMatches = Test-StringCollectionContains -Values @($event.affectedResources) -Expected $ResourceId
        $circuitMatches = Test-StringCollectionContains -Values @($event.affectedCircuits) -Expected $CircuitId

        if ($hasHint -and -not ($resourceMatches -or $circuitMatches)) {
            continue
        }

        $matches.Add($event)
    }

    return @($matches | Sort-Object startTime)
}

Export-ModuleMember -Function Find-MaintenanceEvents
