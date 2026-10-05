$modulePath = Join-Path $PSScriptRoot '..\scripts\modules\MaintenanceCorrelation.psm1'
Import-Module $modulePath -Force

Describe 'Find-MaintenanceEvents' {
    BeforeAll {
        $fixturePath = Join-Path $PSScriptRoot 'fixtures\maintenance\events.json'
        $events = @(Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json)
    }

    It 'matches an overlapping event by circuit ID' {
        $matches = @(Find-MaintenanceEvents `
            -Events $events `
            -IncidentTime ([DateTimeOffset] '2026-10-05T09:00:00Z') `
            -WindowMinutes 15 `
            -CircuitId 'circuit-123')

        $matches.Count | Should Be 1
        $matches[0].eventId | Should Be 'maint-001'
    }

    It 'does not return an event outside the incident window' {
        $matches = @(Find-MaintenanceEvents `
            -Events $events `
            -IncidentTime ([DateTimeOffset] '2026-10-07T09:00:00Z') `
            -WindowMinutes 15 `
            -CircuitId 'circuit-123')

        $matches.Count | Should Be 0
    }

    It 'does not return a time match for a different circuit' {
        $matches = @(Find-MaintenanceEvents `
            -Events $events `
            -IncidentTime ([DateTimeOffset] '2026-10-05T09:00:00Z') `
            -WindowMinutes 15 `
            -CircuitId 'circuit-999')

        $matches.Count | Should Be 0
    }
}
