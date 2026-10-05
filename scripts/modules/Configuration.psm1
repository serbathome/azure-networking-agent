Set-StrictMode -Version Latest

function Get-PocConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file '$Path' was not found."
    }

    try {
        $configuration = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Configuration file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    if ($configuration.schemaVersion -ne '1.0') {
        throw "Unsupported configuration schema version '$($configuration.schemaVersion)'."
    }

    return $configuration
}

Export-ModuleMember -Function Get-PocConfiguration
