---
name: planned-maintenance
description: Correlate Azure, ExpressRoute, provider, or circuit incidents with planned-maintenance records. Use when a timestamped outage, packet loss, or unstable connectivity could overlap maintenance.
---

# Planned maintenance correlation

Use this skill to run the repository's approved, read-only maintenance check.
The script result is evidence. Do not infer provider maintenance from missing
records or from general Azure knowledge.

## Required input

- Incident timestamp with an explicit time zone.

Collect these values when available:

- Azure subscription ID.
- Azure resource ID.
- Circuit ID.
- Correlation window in minutes.

Never invent a missing identifier. A resource or circuit hint improves
correlation but is not required.

For a supplied start and end time, use the midpoint as `IncidentTime` and half
the range, rounded up to whole minutes, as `WindowMinutes`. Confirm this
conversion with the user before execution.

## Approved command

Run only `scripts/Check-PlannedMaintenance.ps1`. Pass values as separate
PowerShell parameters using the call operator.

```powershell
& .\scripts\Check-PlannedMaintenance.ps1 `
  -IncidentTime '2026-10-05T10:15:00+02:00' `
  -SubscriptionId '00000000-0000-0000-0000-000000000000' `
  -ResourceId '/subscriptions/.../providers/...' `
  -CircuitId 'circuit-123' `
  -WindowMinutes 15
```

Omit optional parameters that the user did not provide. Do not pass empty
strings. Do not invoke Azure CLI directly or call functions in
`scripts/modules`.

## Interpretation

Treat the script's JSON as the source of truth:

- `finding`: one or more maintenance records overlap the incident and supplied
  resource or circuit hints.
- `no-finding`: queried sources contain no matching record. This is not proof
  that no maintenance occurred.
- `inconclusive`: available records cannot support a conclusion.
- `error`: the check did not complete. Preserve its error category and summary.

For each finding, preserve:

- Provider and event ID.
- Maintenance start and end times.
- Affected resource or circuit.
- Source reference.
- Confidence and limitations.

Do not claim causation solely from a time overlap. Report matching maintenance
as a leading hypothesis that must be correlated with the affected path.

## Safety

- Perform no write operation.
- Do not broaden scope after an authorization failure.
- Do not expose credentials, tokens, storage keys, or authentication output.
- Do not silently substitute the current time for a missing incident time.
