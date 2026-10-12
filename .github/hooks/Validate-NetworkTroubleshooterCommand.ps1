[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookDecision {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('allow', 'deny')]
        [string] $Decision,
        [Parameter(Mandatory)]
        [string] $Reason
    )

    @{
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            permissionDecision = $Decision
            permissionDecisionReason = $Reason
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

function Deny-Command {
    param([Parameter(Mandatory)][string] $Reason)

    Write-HookDecision -Decision deny -Reason $Reason
    exit 0
}

try {
    $eventData = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20
}
catch {
    Deny-Command 'The tool request could not be validated.'
}

$toolInputProperty = $eventData.PSObject.Properties['tool_input']
$toolName = [string] $eventData.tool_name
if ($null -eq $toolInputProperty -or $null -eq $toolInputProperty.Value) {
    if ($toolName -match '(?i)terminal|execute|shell|powershell') {
        Deny-Command 'Execution is blocked because the command input is unavailable.'
    }

    Write-HookDecision -Decision allow -Reason 'Non-execution tool allowed.'
    exit 0
}

$commandProperty = $toolInputProperty.Value.PSObject.Properties['command']
if ($null -eq $commandProperty) {
    if ($toolName -match '(?i)terminal|execute|shell|powershell') {
        Deny-Command 'Execution is blocked because the command input is unavailable.'
    }

    Write-HookDecision -Decision allow -Reason 'Non-execution tool allowed.'
    exit 0
}

$commandText = $commandProperty.Value
if ($commandText -isnot [string] -or [string]::IsNullOrWhiteSpace($commandText)) {
    Deny-Command 'Execution requires one literal PowerShell command.'
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput(
    $commandText,
    [ref] $tokens,
    [ref] $parseErrors
)
if (@($parseErrors).Count -gt 0) {
    Deny-Command 'Execution is blocked because the PowerShell command is invalid.'
}

$commands = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst]
}, $true))
if ($commands.Count -ne 1) {
    Deny-Command 'Execute exactly one approved diagnostic script per tool call.'
}

$commandAst = $commands[0]
$statements = @($ast.EndBlock.Statements)
if ($statements.Count -ne 1 -or
    $statements[0] -isnot [Management.Automation.Language.PipelineAst] -or
    @($statements[0].PipelineElements).Count -ne 1 -or
    $commandAst.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Ampersand) {
    Deny-Command 'Invoke one approved script directly with the PowerShell call operator.'
}

$commandName = $commandAst.GetCommandName()
if ([string]::IsNullOrWhiteSpace($commandName) -or $commandAst.Redirections.Count -gt 0) {
    Deny-Command 'Dynamic commands and output redirection are not allowed.'
}

$approvedScripts = @{
    'Check-NsgPath.ps1' = @(
        'IncidentTime',
        'SourceIp',
        'DestinationIp',
        'Protocol',
        'DestinationPort',
        'SubscriptionId'
    )
    'Check-PlannedMaintenance.ps1' = @(
        'IncidentTime',
        'SubscriptionId',
        'ResourceId',
        'CircuitId',
        'WindowMinutes'
    )
}

try {
    $resolvedCommand = [IO.Path]::GetFullPath(
        (Join-Path (Get-Location) $commandName)
    )
}
catch {
    Deny-Command 'The diagnostic script path is invalid.'
}

$approvedEntry = $null
foreach ($scriptName in $approvedScripts.Keys) {
    $approvedPath = [IO.Path]::GetFullPath(
        (Join-Path (Get-Location) "scripts\$scriptName")
    )
    if ([string]::Equals(
        $resolvedCommand,
        $approvedPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $approvedEntry = $scriptName
        break
    }
}
if ($null -eq $approvedEntry) {
    Deny-Command 'Only Check-NsgPath.ps1 and Check-PlannedMaintenance.ps1 may be executed.'
}

$elements = @($commandAst.CommandElements)
if (($elements.Count - 1) % 2 -ne 0) {
    Deny-Command 'Every script parameter must have one literal value.'
}

$seenParameters = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
for ($index = 1; $index -lt $elements.Count; $index += 2) {
    $parameter = $elements[$index]
    $value = $elements[$index + 1]
    if ($parameter -isnot [Management.Automation.Language.CommandParameterAst]) {
        Deny-Command 'Only named script parameters are allowed.'
    }
    if ($parameter.ParameterName -notin $approvedScripts[$approvedEntry]) {
        Deny-Command "Parameter '-$($parameter.ParameterName)' is not allowed for $approvedEntry."
    }
    if (-not $seenParameters.Add($parameter.ParameterName)) {
        Deny-Command "Parameter '-$($parameter.ParameterName)' was supplied more than once."
    }
    if ($value -isnot [Management.Automation.Language.StringConstantExpressionAst] -and
        $value -isnot [Management.Automation.Language.ConstantExpressionAst]) {
        Deny-Command 'Parameter values must be literals without variables or subexpressions.'
    }
}

Write-HookDecision -Decision allow -Reason "Approved diagnostic script: $approvedEntry."
