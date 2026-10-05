# Network Troubleshooting Agent PoC

## Purpose

This proof of concept helps network engineers perform the initial analysis of
connectivity incidents from GitHub Copilot in Visual Studio Code.

The PoC correlates ticket parameters with infrastructure data and returns
evidence, findings, and suggested next checks. It does not make configuration
changes, automatically resolve tickets, or claim to prove end-to-end
connectivity.

The implemented scope covers:

1. Planned-maintenance correlation.
2. Azure endpoint topology, bidirectional NSG, and effective-route analysis.

The architecture is intentionally small. It uses one Copilot custom agent and
approved PowerShell scripts that execute read-only Azure CLI commands. A
separate application, MCP server, and multi-agent orchestration are not required
for the initial PoC.

## Required incident data

The agent should collect or derive:

- Ticket or incident identifier.
- Incident timestamp or time window, including time zone.
- Source IP address.
- Destination IP address.
- Protocol.
- Destination port.
- Azure subscription or resource hints, when known.
- Circuit identifier, when known.

If required values are missing, the agent must request them before starting the
affected check. It must not invent missing parameters.

## Prerequisites and setup

The local workstation requires:

- PowerShell 7 or later.
- Pester 3.4 or later for the offline test suite.
- Azure CLI.
- The Azure CLI Resource Graph extension.
- A GitHub Copilot-enabled Visual Studio Code installation.
- An Azure identity with the required read-only permissions.

Install the Resource Graph extension if it is not already available:

```powershell
az extension add --name resource-graph
```

Sign in and activate the required PIM role before using the checks:

```powershell
az login
az account show
```

The committed `config/settings.json` file controls the maintenance correlation
window and optional Table Storage source. It must not contain storage keys or
other credentials.

The PoC does not enforce a subscription allowlist. If `-SubscriptionId` is
omitted, the maintenance check queries all subscriptions accessible to Azure
Resource Graph and the NSG check searches network interfaces through Azure
Resource Graph across the accessible scope. Supply `-SubscriptionId` to narrow
a check.

Run the offline tests:

```powershell
Invoke-Pester .\tests
```

Select **Network Troubleshooter** from the agent picker in VS Code and provide
the incident parameters. The agent is manually selectable and cannot be
automatically invoked as a subagent.

The scripts can also be run directly:

```powershell
& .\scripts\Check-PlannedMaintenance.ps1 `
  -IncidentTime '2026-10-05T10:15:00+02:00' `
  -SubscriptionId '00000000-0000-0000-0000-000000000000' `
  -CircuitId 'circuit-123'

& .\scripts\Check-NsgPath.ps1 `
  -IncidentTime '2026-10-05T10:15:00+02:00' `
  -SourceIp '10.20.1.4' `
  -DestinationIp '192.168.40.10' `
  -Protocol Tcp `
  -DestinationPort 443 `
  -SubscriptionId '00000000-0000-0000-0000-000000000000'
```

## Architecture

```text
┌──────────────────────────────────────────────────────────────┐
│ Network engineer                                            │
│ Visual Studio Code + GitHub Copilot                         │
└────────────────────────────┬─────────────────────────────────┘
                             │ Ticket details
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Network Troubleshooter custom agent                         │
│                                                              │
│ - Validates incident parameters                             │
│ - Selects approved checks                                   │
│ - Invokes independent checks in parallel where possible     │
│ - Correlates structured results                             │
│ - Reports evidence, confidence, and limitations             │
└────────────────────────────┬─────────────────────────────────┘
                             │ Approved script calls only
              ┌──────────────┴──────────────┐
              ▼                             ▼
┌───────────────────────────┐  ┌───────────────────────────────┐
│ Maintenance check         │  │ NSG path check                │
│ PowerShell + Azure CLI    │  │ PowerShell + Azure CLI        │
│                           │  │                               │
│ - Azure maintenance data  │  │ - Resolve Azure source       │
│ - External event records  │  │ - Read NIC and subnet NSGs   │
│ - Time-window correlation │  │ - Read effective rules       │
│ - Circuit correlation     │  │ - Evaluate matching rule     │
└─────────────┬─────────────┘  └──────────────┬────────────────┘
              │                               │
              ▼                               ▼
┌───────────────────────────┐  ┌───────────────────────────────┐
│ Azure APIs and existing   │  │ Azure Resource Manager,       │
│ Table Storage             │  │ Network APIs, and activity    │
│                           │  │ or resource-change records    │
└───────────────────────────┘  └───────────────────────────────┘
```

## Components

### GitHub Copilot custom agent

The custom agent is the interaction and orchestration layer. It:

- Converts the ticket description into validated incident parameters.
- Selects the relevant repository skills.
- Runs maintenance and NSG checks independently.
- Correlates results without changing their underlying evidence.
- Clearly distinguishes facts, hypotheses, and unavailable checks.
- Recommends the next manual investigation step.

The agent must not construct and execute arbitrary Azure CLI commands. It may
only invoke scripts committed to this repository with documented parameters.

### Agent skills

Reusable procedural guidance is stored in:

- `.github/skills/planned-maintenance/SKILL.md`
- `.github/skills/azure-network-path/SKILL.md`

Copilot discovers skills from their frontmatter descriptions and loads their
instructions when the incident matches. Skills explain required inputs, exact
script invocation, output interpretation, limitations, and safety rules. They
do not execute Azure operations themselves and are not a security boundary.

The PowerShell scripts remain the deterministic tools. The agent remains the
orchestrator. Skills prevent the agent definition from duplicating detailed
domain procedures and make those procedures reusable by future agents.

### Script execution layer

Each diagnostic capability is implemented as a focused PowerShell script. The
scripts provide a controlled boundary around Azure CLI and other data sources.

Every script must:

- Accept explicit, typed parameters.
- Validate IP addresses, protocol, ports, timestamps, and Azure identifiers.
- Use the subscriptions visible to the signed-in Azure identity, optionally
  narrowed by an explicit subscription ID.
- Perform read-only operations.
- Use non-interactive Azure CLI commands.
- Emit one structured JSON result to standard output.
- Send diagnostics to standard error.
- Return a non-zero exit code for execution or authentication failures.
- Avoid printing credentials, tokens, or sensitive headers.
- Apply timeouts and result limits to external queries.

Network decisions such as NSG rule matching must be implemented as
deterministic, testable code. They must not depend on language-model reasoning.

### Azure access

For the local PoC, scripts use the network engineer's Azure identity through an
existing Azure CLI login. The engineer activates any required eligible role
through Privileged Identity Management (PIM) before starting the analysis.

The PoC must use least-privilege, read-only access. A custom Azure role may be
required for effective NSG operations that are not covered by ordinary resource
read permissions. Broad write-enabled roles such as Network Contributor should
not be assigned solely for diagnostics.

External credentials, storage keys, and ADM credentials must not be stored in
agent definitions, scripts, command-line arguments, or source control.

## Analysis tools

### Planned-maintenance check

The maintenance script correlates an incident time and affected resource or
circuit with:

- Azure maintenance and health information available through Azure APIs.
- Existing external-provider events stored in Azure Table Storage.

Provider-specific records are converted to a common internal representation:

```json
{
  "provider": "Azure",
  "eventId": "event-123",
  "startTime": "2026-10-05T08:00:00Z",
  "endTime": "2026-10-05T10:00:00Z",
  "status": "active",
  "affectedResources": [],
  "affectedCircuits": ["circuit-123"],
  "sourceReference": "provider record or Azure resource ID"
}
```

The correlation window must be configurable. A suggested initial value is the
incident time plus and minus 15 minutes.

No matching event means only that no matching record was found in the queried
sources. It must not be reported as proof that no maintenance occurred.

### NSG path check

The path script analyzes Azure topology, NSGs, and routes for the supplied flow:

1. Resolve source and destination IPs to Azure NICs.
2. Confirm their subscriptions, VNets, subnets, and direct peering relationship.
3. Retrieve and evaluate source effective outbound NSG rules.
4. Retrieve and evaluate destination effective inbound NSG rules.
5. Resolve the `VirtualNetwork` service tag from discovered VNet address spaces
   and connected peerings that allow VNet access.
6. Select the source effective route toward the destination by longest prefix.
7. Select the destination effective return route toward the source.
8. Return every stage and identify the first blocking or inconclusive hop.

Routes through a virtual appliance or the Internet remain inconclusive because
the next component must be checked separately. A NIC that Azure reports as not
attached to a running VM is reported as a blocking hop.

#### Historical configuration

A query against the current NSG configuration answers whether the flow would be
allowed now. It does not prove what the configuration contained at the incident
time.

Every NSG result must therefore identify its basis as either:

- `current` - evaluated from the current configuration.
- `reconstructed-at-incident-time` - evaluated from sufficiently complete
  historical configuration or change data.

Until historical reconstruction is implemented, the agent must expose this
limitation in its final response.

## Script result contract

All scripts return a common JSON envelope:

```json
{
  "schemaVersion": "1.0",
  "tool": "check-nsg-path",
  "status": "finding",
  "summary": "Outbound TCP/443 is denied by rule Deny-OnPrem-TCP.",
  "confidence": "high",
  "configurationBasis": "current",
  "evidence": [
    {
      "source": "Azure Resource Manager",
      "resourceId": "/subscriptions/.../networkSecurityGroups/example",
      "observation": "Rule Deny-OnPrem-TCP matched at priority 200.",
      "observedAt": "2026-10-05T08:35:00Z"
    }
  ],
  "limitations": [
    "The on-premises firewall was not checked.",
    "The current NSG configuration was used."
  ],
  "durationMs": 840
}
```

Allowed `status` values are:

- `finding` - relevant evidence was found.
- `no-finding` - the query completed but found no relevant evidence.
- `inconclusive` - available data cannot support a conclusion.
- `error` - the check could not be completed.

A successful command execution must not be represented as a positive diagnostic
finding unless the evidence supports it.

## Agent response contract

The final response presented to the engineer should contain:

1. Incident parameters used for the analysis.
2. Findings from each executed check.
3. Supporting resource IDs, rule names, events, and timestamps.
4. A likely explanation, explicitly labeled as a hypothesis.
5. Checks that were unavailable or out of scope.
6. Recommended manual next steps.

For example:

> The Azure outbound NSG permits TCP/443. A maintenance event affecting circuit
> `circuit-123` overlaps the incident by eight minutes, making maintenance the
> leading hypothesis. The on-premises firewall was not checked, so end-to-end
> reachability is not confirmed.

## Repository layout

```text
.github/
  agents/
    network-troubleshooter.agent.md
  skills/
    azure-network-path/
      SKILL.md
    planned-maintenance/
      SKILL.md

scripts/
  Check-PlannedMaintenance.ps1
  Check-NsgPath.ps1
  modules/
    AuditLogger.psm1
    AzureCli.psm1
    AzureMaintenance.psm1
    Configuration.psm1
    MaintenanceCorrelation.psm1
    AzureNetwork.psm1
    NsgEvaluation.psm1
    PathEvaluation.psm1
    ResultContract.psm1
    Validation.psm1

config/
  settings.json

tests/
  MaintenanceCorrelation.Tests.ps1
  NsgEvaluation.Tests.ps1
  PathEvaluation.Tests.ps1
  ResultContract.Tests.ps1
  Validation.Tests.ps1
  fixtures/
    maintenance/
    nsg/

.gitignore
Notes.md
README.md
```

The specialist capabilities are tools used by the main agent, not separate
agents. Additional scripts can be added behind the same contracts without
changing the overall interaction model.

## Security and operational guardrails

- Permit only approved read-only scripts.
- Validate all values before including them in an Azure CLI invocation.
- Pass arguments as PowerShell parameters rather than constructing command
  strings.
- Use a dedicated read-only PoC identity when broad subscription discovery is
  not appropriate for the engineer's normal account.
- Record the tool name, target scope, start time, duration, status, and error
  category for each invocation.
- Avoid placing full ticket descriptions, credentials, or tokens in logs.
- Preserve Azure API errors instead of returning success-shaped fallback data.
- Do not automatically remediate or modify Azure resources.
- Treat IP addresses, topology, resource IDs, and ticket contents according to
  the client's data-handling requirements.

## Future extension

The script-first architecture can add tools for:

- Effective routes and next-hop analysis.
- ExpressRoute metrics and availability.
- Azure Firewall logs.
- FortiAnalyzer or FortiGate blocking events.
- Tufin SecureTrack path discovery.
- Additional maintenance providers.

If the PoC proves valuable and needs centralized execution, stronger tool
discovery, or use outside VS Code, the script modules can later be wrapped by an
MCP server or hosted API. The agent's input and result contracts should remain
stable, so this evolution does not require redesigning the diagnostic logic.

## PoC validation

The PoC should be evaluated with sanitized historical incidents. Suggested
success criteria are:

- Median initial-analysis time below two minutes.
- Correct matching NSG rule for known NSG cases.
- Correct maintenance correlation for known events.
- Evidence included for every reported finding.
- Explicit inconclusive results when a source is unavailable.
- No infrastructure write operations.
- No credentials or access tokens in output or logs.
- Useful next-step guidance when a root cause cannot be established.