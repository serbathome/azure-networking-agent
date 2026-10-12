[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $IncidentTime,

    [Parameter(Mandatory)]
    [string] $SourceIp,

    [Parameter(Mandatory)]
    [string] $DestinationIp,

    [Parameter(Mandatory)]
    [ValidateSet('Tcp', 'Udp', 'Icmp', 'Any')]
    [string] $Protocol,

    [Nullable[int]] $DestinationPort,

    [string] $SubscriptionId,

    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\settings.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $modulePath 'AuditLogger.psm1') -Force
Import-Module (Join-Path $modulePath 'AzureCli.psm1') -Force
Import-Module (Join-Path $modulePath 'AzureNetwork.psm1') -Force
Import-Module (Join-Path $modulePath 'Configuration.psm1') -Force
Import-Module (Join-Path $modulePath 'NsgEvaluation.psm1') -Force
Import-Module (Join-Path $modulePath 'PathEvaluation.psm1') -Force
Import-Module (Join-Path $modulePath 'ResultContract.psm1') -Force
Import-Module (Join-Path $modulePath 'Validation.psm1') -Force

function Find-Nic {
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $Address,
        [string[]] $Subscriptions
    )

    if (@($Subscriptions).Count -gt 0) {
        return Find-AzureNetworkInterfaceByPrivateIp -PrivateIpAddress $Address -SubscriptionIds $Subscriptions
    }

    return Find-AzureNetworkInterfaceByPrivateIp -PrivateIpAddress $Address
}

function Test-AddressInPrefixes {
    param(
        [Parameter(Mandatory)]
        [System.Net.IPAddress] $Address,
        [string[]] $Prefixes
    )

    foreach ($prefix in @($Prefixes)) {
        if (Test-IpInCidr -Address $Address -Cidr $prefix) {
            return $true
        }
    }

    return $false
}

function New-PathStage {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [ValidateSet('allowed', 'blocked', 'inconclusive')]
        [string] $Status,
        [Parameter(Mandatory)]
        [string] $Summary,
        [string] $ResourceId
    )

    return [pscustomobject] @{
        name = $Name
        status = $Status
        summary = $Summary
        resourceId = $ResourceId
    }
}

function Test-RunningNicError {
    param([string] $Message)

    return $Message -match 'NicMustBeAttachedToRunningVm'
}

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$toolName = 'check-nsg-path'
$targetScope = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { 'all-accessible-subscriptions' } else { $SubscriptionId }
Write-AuditEvent -Tool $toolName -TargetScope $targetScope -Status started

try {
    $incident = ConvertTo-IncidentTime -Value $IncidentTime
    $sourceAddress = Assert-IpAddress -Value $SourceIp -ParameterName SourceIp
    $destinationAddress = Assert-IpAddress -Value $DestinationIp -ParameterName DestinationIp
    if ($Protocol -in @('Tcp', 'Udp') -and $null -eq $DestinationPort) {
        throw "DestinationPort is required when Protocol is '$Protocol'."
    }
    if ($null -ne $DestinationPort) {
        [void] (Assert-Port -Value $DestinationPort -ParameterName DestinationPort)
    }
    [void] (Get-PocConfiguration -Path $ConfigPath)
    Assert-AzureCliAuthenticated

    $subscriptions = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        @()
    }
    else {
        @(Assert-SubscriptionId -Value $SubscriptionId)
    }

    $sourceSearch = Find-Nic -Address $sourceAddress -Subscriptions $subscriptions
    $destinationSearch = Find-Nic -Address $destinationAddress -Subscriptions $subscriptions
    $sourceNic = $sourceSearch.match
    $destinationNic = $destinationSearch.match

    if ($null -eq $sourceNic -or $null -eq $destinationNic) {
        $missing = @()
        if ($null -eq $sourceNic) { $missing += "source IP '$SourceIp'" }
        if ($null -eq $destinationNic) { $missing += "destination IP '$DestinationIp'" }
        $stopwatch.Stop()
        $result = New-ToolResult `
            -Tool $toolName `
            -Status inconclusive `
            -Summary "Azure NIC resolution failed for $($missing -join ' and ')." `
            -Confidence none `
            -ConfigurationBasis current `
            -Limitations @('Both endpoints must resolve to Azure NICs for bidirectional NSG and route analysis.') `
            -DurationMs ([int] $stopwatch.ElapsedMilliseconds)
        Write-AuditEvent -Tool $toolName -TargetScope $targetScope -Status inconclusive -DurationMs $result.durationMs
        $result | Write-ToolResult
        return
    }

    $sourceTopology = Get-NetworkTopology -NetworkInterfaceMatch $sourceNic
    $destinationTopology = Get-NetworkTopology -NetworkInterfaceMatch $destinationNic
    $sourceVirtualNetworkPrefixes = @(
        Get-VirtualNetworkServicePrefixes -LocalTopology $sourceTopology -RemoteTopology $destinationTopology
    )
    $destinationVirtualNetworkPrefixes = @(
        Get-VirtualNetworkServicePrefixes -LocalTopology $destinationTopology -RemoteTopology $sourceTopology
    )

    $sameVirtualNetwork = [string]::Equals(
        $sourceTopology.virtualNetworkId,
        $destinationTopology.virtualNetworkId,
        [StringComparison]::OrdinalIgnoreCase
    )
    $bidirectionalVirtualNetworkAccess = $sameVirtualNetwork -or (
        (Test-AddressInPrefixes -Address $destinationAddress -Prefixes $sourceVirtualNetworkPrefixes) -and
        (Test-AddressInPrefixes -Address $sourceAddress -Prefixes $destinationVirtualNetworkPrefixes)
    )
    $relationship = if ($sameVirtualNetwork) {
        'same virtual network'
    }
    elseif ($bidirectionalVirtualNetworkAccess) {
        'connected bidirectional VNet peering'
    }
    else {
        'no direct bidirectional VNet relationship confirmed'
    }

    $stages = [Collections.Generic.List[object]]::new()
    $stages.Add((New-PathStage `
        -Name 'source-topology' `
        -Status allowed `
        -Summary "Source NIC '$($sourceTopology.networkInterfaceName)' is in subscription '$($sourceTopology.subscriptionId)', VNet '$($sourceTopology.virtualNetworkName)', subnet '$($sourceTopology.subnetName)'." `
        -ResourceId $sourceTopology.networkInterfaceId))
    $stages.Add((New-PathStage `
        -Name 'destination-topology' `
        -Status allowed `
        -Summary "Destination NIC '$($destinationTopology.networkInterfaceName)' is in subscription '$($destinationTopology.subscriptionId)', VNet '$($destinationTopology.virtualNetworkName)', subnet '$($destinationTopology.subnetName)'; relationship: $relationship." `
        -ResourceId $destinationTopology.networkInterfaceId))

    foreach ($nsgCheck in @(
        [pscustomobject] @{
            name = 'source-outbound-nsg'
            nic = $sourceNic
            topology = $sourceTopology
            direction = 'Outbound'
            prefixes = $sourceVirtualNetworkPrefixes
        },
        [pscustomobject] @{
            name = 'destination-inbound-nsg'
            nic = $destinationNic
            topology = $destinationTopology
            direction = 'Inbound'
            prefixes = $destinationVirtualNetworkPrefixes
        }
    )) {
        try {
            $rules = @(Get-EffectiveNsgRules -NetworkInterfaceMatch $nsgCheck.nic)
            if ($rules.Count -eq 0) {
                $stages.Add((New-PathStage `
                    -Name $nsgCheck.name `
                    -Status inconclusive `
                    -Summary "Azure returned no effective $($nsgCheck.direction.ToLowerInvariant()) NSG rules." `
                    -ResourceId $nsgCheck.topology.networkInterfaceId))
                continue
            }

            $decision = Get-NsgRuleDecision `
                -Rules $rules `
                -Direction $nsgCheck.direction `
                -SourceAddress $sourceAddress `
                -DestinationAddress $destinationAddress `
                -Protocol $Protocol `
                -DestinationPort $DestinationPort `
                -VirtualNetworkPrefixes $nsgCheck.prefixes

            if ($decision.status -eq 'matched') {
                $access = [string] $decision.access
                $status = if ([string]::Equals($access, 'Deny', [StringComparison]::OrdinalIgnoreCase)) {
                    'blocked'
                }
                else {
                    'allowed'
                }
                $stages.Add((New-PathStage `
                    -Name $nsgCheck.name `
                    -Status $status `
                    -Summary "$($nsgCheck.direction) rule '$($decision.rule.name)' at priority $($decision.rule.priority) returned '$access' for $(if ($null -eq $DestinationPort) { $Protocol } else { "$Protocol/$DestinationPort" })." `
                    -ResourceId ([string] $decision.rule.networkSecurityGroupId)))
            }
            else {
                $ruleName = if ($null -ne $decision.rule) { " Rule '$($decision.rule.name)'." } else { '' }
                $stages.Add((New-PathStage `
                    -Name $nsgCheck.name `
                    -Status inconclusive `
                    -Summary "$($decision.reason)$ruleName" `
                    -ResourceId $nsgCheck.topology.networkInterfaceId))
            }
        }
        catch {
            $message = $_.Exception.Message
            $notRunning = Test-RunningNicError -Message $message
            $stages.Add((New-PathStage `
                -Name $nsgCheck.name `
                -Status $(if ($notRunning) { 'blocked' } else { 'inconclusive' }) `
                -Summary $(if ($notRunning) {
                    "NIC '$($nsgCheck.topology.networkInterfaceName)' is not attached to a running VM, so the endpoint cannot currently pass traffic and effective NSGs are unavailable."
                } else {
                    "Effective NSG retrieval failed: $message"
                }) `
                -ResourceId $nsgCheck.topology.networkInterfaceId))
        }
    }

    foreach ($routeCheck in @(
        [pscustomobject] @{
            name = 'source-forward-route'
            nic = $sourceNic
            topology = $sourceTopology
            target = $destinationAddress
        },
        [pscustomobject] @{
            name = 'destination-return-route'
            nic = $destinationNic
            topology = $destinationTopology
            target = $sourceAddress
        }
    )) {
        try {
            $routes = @(Get-EffectiveRoutes -NetworkInterfaceMatch $routeCheck.nic)
            $decision = Get-RouteDecision -Routes $routes -DestinationAddress $routeCheck.target
            $nextHop = if ($null -ne $decision.route) { [string] $decision.route.nextHopType } else { 'unknown' }
            $nextHopIps = if ($null -ne $decision.route) {
                @($decision.route.nextHopIpAddress) -join ', '
            }
            else {
                ''
            }
            $nextHopDetail = if ([string]::IsNullOrWhiteSpace($nextHopIps)) { $nextHop } else { "$nextHop ($nextHopIps)" }
            $stages.Add((New-PathStage `
                -Name $routeCheck.name `
                -Status $decision.status `
                -Summary "$($decision.reason) Selected next hop: $nextHopDetail." `
                -ResourceId $routeCheck.topology.networkInterfaceId))
        }
        catch {
            $message = $_.Exception.Message
            $notRunning = Test-RunningNicError -Message $message
            $stages.Add((New-PathStage `
                -Name $routeCheck.name `
                -Status $(if ($notRunning) { 'blocked' } else { 'inconclusive' }) `
                -Summary $(if ($notRunning) {
                    "NIC '$($routeCheck.topology.networkInterfaceName)' is not attached to a running VM, so effective routes are unavailable."
                } else {
                    "Effective route retrieval failed: $message"
                }) `
                -ResourceId $routeCheck.topology.networkInterfaceId))
        }
    }

    $firstIssue = Get-FirstPathIssue -Stages $stages
    $hasBlockingStage = @($stages | Where-Object { $_.status -eq 'blocked' }).Count -gt 0
    $status = if ($hasBlockingStage) {
        'finding'
    }
    elseif ($null -ne $firstIssue) {
        'inconclusive'
    }
    else {
        'no-finding'
    }
    $confidence = if ($status -eq 'inconclusive') { 'low' } else { 'high' }
    $summary = if ($null -ne $firstIssue) {
        "First blocking or inconclusive hop: $($firstIssue.name). $($firstIssue.summary)"
    }
    else {
        'Both endpoints resolved, bidirectional NSGs allow the flow, and forward and return routes have usable Azure next hops.'
    }

    $evidence = foreach ($stage in $stages) {
        New-Evidence `
            -Source "Azure path stage: $($stage.name)" `
            -ResourceId $stage.resourceId `
            -Observation "[$($stage.status)] $($stage.summary)" `
            -ObservedAt $incident
    }

    $stopwatch.Stop()
    $limitations = @(
        'The current NSG and route configuration was evaluated; historical state was not reconstructed.',
        'Azure Firewall, network virtual appliances, guest firewalls, DNS, and application health require separate checks when present.'
    )
    $result = New-ToolResult `
        -Tool $toolName `
        -Status $status `
        -Summary $summary `
        -Confidence $confidence `
        -ConfigurationBasis current `
        -Evidence $evidence `
        -Limitations $limitations `
        -DurationMs ([int] $stopwatch.ElapsedMilliseconds)

    Write-AuditEvent -Tool $toolName -TargetScope "$($sourceTopology.networkInterfaceId) -> $($destinationTopology.networkInterfaceId)" -Status $result.status -DurationMs $result.durationMs
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
        -ConfigurationBasis current `
        -Limitations @('The Azure path check did not complete.') `
        -DurationMs ([int] $stopwatch.ElapsedMilliseconds) `
        -ErrorCategory $category
    Write-AuditEvent -Tool $toolName -TargetScope $targetScope -Status error -DurationMs $result.durationMs -ErrorCategory $category
    $result | Write-ToolResult
    exit 1
}
