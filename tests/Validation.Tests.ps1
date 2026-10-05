$modulePath = Join-Path $PSScriptRoot '..\scripts\modules\Validation.psm1'
Import-Module $modulePath -Force

Describe 'Input validation' {
    It 'accepts an incident timestamp with an explicit time zone' {
        $value = ConvertTo-IncidentTime -Value '2026-10-05T10:15:00+02:00'
        $value.ToString('o') | Should Be '2026-10-05T08:15:00.0000000+00:00'
    }

    It 'rejects an incident timestamp without a time zone' {
        $threw = $false
        try {
            [void] (ConvertTo-IncidentTime -Value '2026-10-05T10:15:00')
        }
        catch {
            $threw = $true
        }
        $threw | Should Be $true
    }

    It 'rejects an invalid destination port' {
        $threw = $false
        try {
            [void] (Assert-Port -Value 70000)
        }
        catch {
            $threw = $true
        }
        $threw | Should Be $true
    }

    It 'rejects an invalid subscription ID' {
        $threw = $false
        try {
            [void] (Assert-SubscriptionId -Value 'production')
        }
        catch {
            $threw = $true
        }
        $threw | Should Be $true
    }
}
