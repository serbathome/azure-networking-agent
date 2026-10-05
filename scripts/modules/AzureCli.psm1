Set-StrictMode -Version Latest

function Invoke-AzureCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Arguments,

        [ValidateRange(1, 600)]
        [int] $TimeoutSeconds = 120
    )

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ([string]::IsNullOrEmpty($Arguments[$index])) {
            throw "Azure CLI argument at index $index is empty."
        }
    }

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    if ($null -eq $azCommand) {
        throw 'Azure CLI was not found. Install Azure CLI and sign in before running this check.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $launcherArguments = @()
    if ([IO.Path]::GetExtension($azCommand.Source) -eq '.cmd') {
        $pythonPath = [IO.Path]::GetFullPath((Join-Path (Split-Path $azCommand.Source -Parent) '..\python.exe'))
        if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
            throw "The Azure CLI launcher '$($azCommand.Source)' is not backed by the expected Python executable."
        }
        $startInfo.FileName = $pythonPath
        $launcherArguments = @('-IBm', 'azure.cli')
    }
    else {
        $startInfo.FileName = $azCommand.Source
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    foreach ($argument in $launcherArguments + @($Arguments) + @('--output', 'json', '--only-show-errors')) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw 'Azure CLI process could not be started.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "Azure CLI command exceeded the $TimeoutSeconds second timeout."
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            $message = if ([string]::IsNullOrWhiteSpace($stderr)) {
                "Azure CLI exited with code $($process.ExitCode)."
            }
            else {
                $stderr.Trim()
            }

            throw "Azure CLI command failed: $message"
        }

        if ([string]::IsNullOrWhiteSpace($stdout)) {
            return $null
        }

        try {
            return $stdout | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Azure CLI returned invalid JSON: $($_.Exception.Message)"
        }
    }
    finally {
        $process.Dispose()
    }
}

function Assert-AzureCliAuthenticated {
    [CmdletBinding()]
    param()

    [void] (Invoke-AzureCliJson -Arguments @('account', 'show') -TimeoutSeconds 30)
}

function Get-AzureSubscriptionIds {
    [CmdletBinding()]
    param()

    $accounts = @(Invoke-AzureCliJson -Arguments @('account', 'list', '--all') -TimeoutSeconds 60)
    $subscriptionIds = @(
        $accounts |
            Where-Object { [string]::Equals([string] $_.state, 'Enabled', [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { [string] $_.id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    if ($subscriptionIds.Count -eq 0) {
        throw 'No enabled Azure subscriptions are visible to the signed-in identity.'
    }

    return $subscriptionIds
}

Export-ModuleMember -Function Invoke-AzureCliJson, Assert-AzureCliAuthenticated, Get-AzureSubscriptionIds
