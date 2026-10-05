Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AzureCli.psm1')

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)]
        [psobject] $InputObject,
        [Parameter(Mandatory)]
        [string] $PropertyName
    )

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-NormalizedAzureEvent {
    param(
        [Parameter(Mandatory)]
        [psobject] $Event
    )

    $startTime = [string] $Event.startTime
    if ([string]::IsNullOrWhiteSpace($startTime)) {
        return $null
    }

    $endTime = [string] $Event.endTime
    if ([string]::IsNullOrWhiteSpace($endTime)) {
        $endTime = $startTime
    }

    $affectedResources = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string] $Event.subscriptionId)) {
        $affectedResources.Add("/subscriptions/$($Event.subscriptionId)")
    }
    if ($null -ne $Event.affectedResources) {
        foreach ($resource in @($Event.affectedResources)) {
            if ($resource -is [string] -and -not [string]::IsNullOrWhiteSpace($resource)) {
                $affectedResources.Add($resource)
            }
        }
    }

    return [pscustomobject] [ordered] @{
        provider = 'Azure'
        eventId = [string] $Event.eventId
        title = [string] $Event.title
        startTime = $startTime
        endTime = $endTime
        status = [string] $Event.status
        affectedResources = @($affectedResources)
        affectedCircuits = @()
        sourceReference = [string] $Event.sourceReference
    }
}

function Get-AzurePlannedMaintenanceEvents {
    [CmdletBinding()]
    param(
        [string[]] $SubscriptionIds
    )

    $query = @"
servicehealthresources
| where type =~ 'microsoft.resourcehealth/events'
| extend eventType = tostring(properties.EventType)
| where eventType =~ 'PlannedMaintenance'
| project eventId = coalesce(tostring(properties.TrackingId), name),
          title = tostring(properties.Title),
          status = tostring(properties.Status),
          startTime = tostring(properties.ImpactStartTime),
          endTime = tostring(properties.ImpactMitigationTime),
          affectedResources = properties.AffectedResources,
          subscriptionId = subscriptionId,
          sourceReference = id
"@

    $arguments = @('graph', 'query', '--graph-query', $query, '--first', '1000')
    $specifiedSubscriptionIds = @(
        $SubscriptionIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($specifiedSubscriptionIds.Count -gt 0) {
        $arguments += @('--subscriptions') + $specifiedSubscriptionIds
    }
    $response = Invoke-AzureCliJson -Arguments $arguments -TimeoutSeconds 120
    $events = if ($null -ne $response -and $null -ne $response.data) {
        @($response.data)
    }
    else {
        @()
    }

    $normalized = foreach ($event in $events) {
        $converted = ConvertTo-NormalizedAzureEvent -Event $event
        if ($null -ne $converted) {
            $converted
        }
    }

    return @($normalized)
}

function Get-ExternalMaintenanceEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $StorageConfiguration
    )

    if (-not [bool] $StorageConfiguration.enabled) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace([string] $StorageConfiguration.accountName) -or
        [string]::IsNullOrWhiteSpace([string] $StorageConfiguration.tableName)) {
        throw 'Maintenance storage is enabled, but accountName or tableName is missing.'
    }

    $response = Invoke-AzureCliJson -Arguments @(
        'storage', 'entity', 'query',
        '--auth-mode', 'login',
        '--account-name', [string] $StorageConfiguration.accountName,
        '--table-name', [string] $StorageConfiguration.tableName,
        '--num-results', '1000'
    ) -TimeoutSeconds 120

    $itemsProperty = if ($null -ne $response) { $response.PSObject.Properties['items'] } else { $null }
    $entities = if ($null -ne $itemsProperty -and $null -ne $itemsProperty.Value) {
        @($itemsProperty.Value)
    }
    else {
        @($response)
    }

    $columns = $StorageConfiguration.columns
    $normalized = foreach ($entity in $entities) {
        if ($null -eq $entity) {
            continue
        }

        $startTime = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName ([string] $columns.startTime))
        if ([string]::IsNullOrWhiteSpace($startTime)) {
            continue
        }

        $endTime = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName ([string] $columns.endTime))
        if ([string]::IsNullOrWhiteSpace($endTime)) {
            $endTime = $startTime
        }

        $provider = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName ([string] $columns.provider))
        if ([string]::IsNullOrWhiteSpace($provider)) {
            $provider = 'External'
        }

        $eventId = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName ([string] $columns.eventId))
        if ([string]::IsNullOrWhiteSpace($eventId)) {
            $eventId = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName 'RowKey')
        }

        $resourceId = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName ([string] $columns.resourceId))
        $circuitId = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName ([string] $columns.circuitId))

        [pscustomobject] [ordered] @{
            provider = $provider
            eventId = $eventId
            title = 'External planned maintenance'
            startTime = $startTime
            endTime = $endTime
            status = [string] (Get-ObjectPropertyValue -InputObject $entity -PropertyName ([string] $columns.status))
            affectedResources = @($resourceId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            affectedCircuits = @($circuitId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            sourceReference = "Table:$($StorageConfiguration.tableName)/Row:$eventId"
        }
    }

    return @($normalized)
}

Export-ModuleMember -Function Get-AzurePlannedMaintenanceEvents, Get-ExternalMaintenanceEvents
