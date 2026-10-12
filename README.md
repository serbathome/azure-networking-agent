# Network Troubleshooting Agent PoC

A GitHub Copilot custom agent for initial, read-only analysis of Azure network
connectivity and planned-maintenance incidents.

The agent runs deterministic PowerShell checks and reports evidence,
hypotheses, limitations, and recommended next steps. It does not modify Azure
resources or prove end-to-end connectivity.

## Current capabilities

- Correlate an incident with Azure planned-maintenance records and an optional
  Azure Table Storage source.
- Resolve source and destination Azure NICs.
- Evaluate outbound and inbound effective NSG rules.
- Evaluate forward and return effective routes.
- Report the first blocked or inconclusive path stage.

## Prerequisites

- Visual Studio Code with GitHub Copilot
- PowerShell 7+
- Azure CLI with the Resource Graph extension
- An authenticated Azure identity with read access to the relevant resources

```powershell
az extension add --name resource-graph
az login
az account show
```

## Use the agent

Select **Network Troubleshooter** from the VS Code agent picker and provide:

- Incident time with time zone
- Source and destination IP addresses
- Protocol and destination port for TCP or UDP
- Subscription, resource, or circuit identifiers when known

The agent uses the repository skills to select and run the approved checks.
When no subscription is supplied, scripts search all subscriptions visible to
the signed-in identity. An agent-scoped pre-tool hook blocks terminal commands
other than direct invocations of the two diagnostic scripts.

## Run checks directly

```powershell
& .\scripts\Check-NsgPath.ps1 `
  -IncidentTime '2026-10-05T10:15:00+02:00' `
  -SourceIp '10.20.1.4' `
  -DestinationIp '192.168.40.10' `
  -Protocol Tcp `
  -DestinationPort 443 `
  -SubscriptionId '00000000-0000-0000-0000-000000000000'
```

```powershell
& .\scripts\Check-PlannedMaintenance.ps1 `
  -IncidentTime '2026-10-05T10:15:00+02:00' `
  -SubscriptionId '00000000-0000-0000-0000-000000000000' `
  -CircuitId 'circuit-123'
```

Optional parameters may be omitted. Both scripts return a structured JSON
result with a status of `finding`, `no-finding`, `inconclusive`, or `error`.

## Configuration

[`config/settings.json`](config/settings.json) controls the maintenance
correlation window and optional Table Storage source. Table Storage is disabled
by default. Do not store credentials in this file.

## Repository layout

```text
.github/
  agents/network-troubleshooter.agent.md
  hooks/Validate-NetworkTroubleshooterCommand.ps1
  skills/azure-network-path/SKILL.md
  skills/planned-maintenance/SKILL.md
config/
  settings.json
scripts/
  Check-NsgPath.ps1
  Check-PlannedMaintenance.ps1
  modules/
```

## Limitations

- NSG and route analysis uses current Azure configuration, not reconstructed
  configuration from the incident time.
- Both endpoints must resolve to Azure NICs for full bidirectional analysis.
- Routes through gateways, virtual appliances, or the Internet require
  separate downstream checks.
- A missing maintenance match does not prove that no maintenance occurred.
- On-premises firewalls and other external network components are out of scope.
