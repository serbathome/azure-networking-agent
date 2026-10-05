[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $IncidentTime,

    [string] $SubscriptionId,

    [string] $ResourceId,

    [string] $CircuitId,

    [ValidateRange(0, 1440)]
    [int] $WindowMinutes,

    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\settings.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $modulePath 'AuditLogger.psm1') -Force
Import-Module (Join-Path $modulePath 'AzureCli.psm1') -Force
Import-Module (Join-Path $modulePath 'AzureMaintenance.psm1') -Force
Import-Module (Join-Path $modulePath 'Configuration.psm1') -Force
Import-Module (Join-Path $modulePath 'MaintenanceCorrelation.psm1') -Force
Import-Module (Join-Path $modulePath 'ResultContract.psm1') -Force
Import-Module (Join-Path $modulePath 'Validation.psm1') -Force

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$toolName = 'check-planned-maintenance'
$targetScope = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { 'all-accessible-subscriptions' } else { $SubscriptionId }
Write-AuditEvent -Tool $toolName -TargetScope $targetScope -Status started

try {
    $incident = ConvertTo-IncidentTime -Value $IncidentTime
    if (-not [string]::IsNullOrWhiteSpace($ResourceId)) {
        $ResourceId = Assert-ResourceId -Value $ResourceId
    }

    $configuration = Get-PocConfiguration -Path $ConfigPath
    $subscriptions = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        @()
    }
    else {
        @(Assert-SubscriptionId -Value $SubscriptionId)
    }
    Assert-AzureCliAuthenticated

    $configuredWindow = 15
    if ($null -ne $configuration.maintenance -and
        $null -ne $configuration.maintenance.correlationWindowMinutes) {
        $configuredWindow = [int] $configuration.maintenance.correlationWindowMinutes
    }
    $effectiveWindow = if ($PSBoundParameters.ContainsKey('WindowMinutes')) {
        $WindowMinutes
    }
    else {
        $configuredWindow
    }

    $events = [Collections.Generic.List[object]]::new()
    $azureEvents = if (@($subscriptions).Count -gt 0) {
        @(Get-AzurePlannedMaintenanceEvents -SubscriptionIds $subscriptions)
    }
    else {
        @(Get-AzurePlannedMaintenanceEvents)
    }
    foreach ($event in $azureEvents) {
        $events.Add($event)
    }

    if ($null -ne $configuration.maintenance -and $null -ne $configuration.maintenance.storage) {
        foreach ($event in @(Get-ExternalMaintenanceEvents -StorageConfiguration $configuration.maintenance.storage)) {
            $events.Add($event)
        }
    }

    $matches = @(Find-MaintenanceEvents `
        -Events $events `
        -IncidentTime $incident `
        -WindowMinutes $effectiveWindow `
        -ResourceId $ResourceId `
        -CircuitId $CircuitId)

    $evidence = foreach ($match in $matches) {
        $observation = "'$($match.title)' from $($match.provider) overlaps the incident window ($($match.startTime) to $($match.endTime))."
        New-Evidence `
            -Source ([string] $match.provider) `
            -ResourceId ([string] $match.sourceReference) `
            -Observation $observation `
            -ObservedAt $incident
    }

    $stopwatch.Stop()
    if ($matches.Count -gt 0) {
        $result = New-ToolResult `
            -Tool $toolName `
            -Status finding `
            -Summary "$($matches.Count) planned-maintenance event(s) matched the incident window and supplied resource or circuit hints." `
            -Confidence high `
            -Evidence $evidence `
            -Limitations @('Only configured Azure and Table Storage sources were queried.') `
            -DurationMs ([int] $stopwatch.ElapsedMilliseconds)
    }
    else {
        $result = New-ToolResult `
            -Tool $toolName `
            -Status no-finding `
            -Summary 'No matching planned-maintenance record was found in the configured sources.' `
            -Confidence medium `
            -Limitations @('No matching record does not prove that no maintenance occurred.', 'Only configured Azure and Table Storage sources were queried.') `
            -DurationMs ([int] $stopwatch.ElapsedMilliseconds)
    }

    Write-AuditEvent -Tool $toolName -TargetScope $targetScope -Status $result.status -DurationMs $result.durationMs
    $result | Write-ToolResult
}
catch {
    $stopwatch.Stop()
    $category = $_.Exception.GetType().Name
    $result = New-ToolResult `
        -Tool $toolName `
        -Status error `
        -Summary $_.Exception.Message `
        -Confidence none `
        -Limitations @('The maintenance check did not complete.') `
        -DurationMs ([int] $stopwatch.ElapsedMilliseconds) `
        -ErrorCategory $category
    Write-AuditEvent -Tool $toolName -TargetScope $targetScope -Status error -DurationMs $result.durationMs -ErrorCategory $category
    $result | Write-ToolResult
    exit 1
}
