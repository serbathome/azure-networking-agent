Set-StrictMode -Version Latest

function Write-AuditEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Tool,

        [Parameter(Mandatory)]
        [string] $TargetScope,

        [Parameter(Mandatory)]
        [ValidateSet('started', 'finding', 'no-finding', 'inconclusive', 'error')]
        [string] $Status,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $DurationMs = 0,

        [string] $ErrorCategory
    )

    $record = [ordered] @{
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        tool = $Tool
        targetScope = $TargetScope
        status = $Status
        durationMs = $DurationMs
    }

    if (-not [string]::IsNullOrWhiteSpace($ErrorCategory)) {
        $record.errorCategory = $ErrorCategory
    }

    [Console]::Error.WriteLine(($record | ConvertTo-Json -Compress))
}

Export-ModuleMember -Function Write-AuditEvent
