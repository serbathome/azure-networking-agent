---
name: azure-network-path
description: Analyze Azure private IP connectivity, NSG denies, effective routes, routing, and VNet paths across two endpoint NICs. Use for incidents with source IP, destination IP, protocol, and incident time.
---

# Azure network path analysis

Use this skill to execute and interpret the repository's deterministic,
read-only Azure path check. The script evaluates current Azure topology and
configuration; the language model must not reimplement NSG or route decisions.

## Required input

Collect all of these values before execution:

- Incident timestamp with an explicit time zone.
- Source IP address.
- Destination IP address.
- Network protocol: `Tcp`, `Udp`, `Icmp`, or `Any`.
- Destination port for TCP or UDP.

Collect the Azure subscription ID when known. If omitted, the script searches
the Azure Resource Graph scope visible to the signed-in identity.

The destination port is not used for `Icmp`. For `Any`, omit the port to
evaluate protocol-independent rules; port-specific rules may make the result
inconclusive.

Translate application protocols to their network parameters only when
unambiguous. For example, SSH normally means TCP/22. Confirm the translation
with the user when the ticket does not already provide TCP and port 22.

## Approved command

Run only `scripts/Check-NsgPath.ps1`. Pass values as separate named parameters.

```powershell
& .\scripts\Check-NsgPath.ps1 `
  -IncidentTime '2026-10-05T10:15:00+02:00' `
  -SourceIp '10.0.1.4' `
  -DestinationIp '10.0.1.6' `
  -Protocol Tcp `
  -DestinationPort 22 `
  -SubscriptionId '00000000-0000-0000-0000-000000000000'
```

Omit `-SubscriptionId` when it is unknown. Do not pass empty strings. Do not
invoke Azure CLI directly or call functions in `scripts/modules`.

## Ordered path stages

The script returns evidence for these stages:

1. `source-topology`: source NIC, subscription, VNet, and subnet.
2. `destination-topology`: destination NIC, subscription, VNet, subnet, and
   direct VNet relationship.
3. `source-outbound-nsg`: effective outbound NSG decision.
4. `destination-inbound-nsg`: effective inbound NSG decision.
5. `source-forward-route`: longest-prefix route from source to destination.
6. `destination-return-route`: longest-prefix route from destination to source.

The script resolves the `VirtualNetwork` service tag using discovered local
VNet address spaces and connected peerings that allow VNet access. Other
unresolved service tags remain inconclusive.

## Interpretation

Treat the script's JSON and ordered evidence as the source of truth:

- `finding`: at least one stage is blocked.
- `no-finding`: all evaluated NSG and route stages allow the flow.
- `inconclusive`: no block was proven, but at least one stage could not be
  decided.
- `error`: the path check did not complete.

For stage observations:

- `allowed`: continue to the next stage.
- `blocked`: report this as a root-cause candidate.
- `inconclusive`: report the missing component or data, without converting it
  to allow or deny.

The summary identifies the first blocking or inconclusive hop. Preserve all
later stage evidence because it can reveal additional failures.

### Route interpretation

- `VnetLocal` or `VNetPeering`: Azure has a usable direct network next hop.
- `VirtualNetworkGateway`: Azure forwards the route to a gateway; the gateway
  and remote path remain unchecked.
- `VirtualAppliance`: the NVA or firewall must be checked separately.
- `Internet`: the external path must be checked separately and is not proof of
  reachability.
- `None`: Azure discards traffic for the selected prefix.

### Endpoint state

When Azure reports `NicMustBeAttachedToRunningVm`, treat the affected endpoint
as blocked. Effective NSGs or routes cannot be retrieved because the NIC is not
attached to a running VM.

### Historical limitation

`configurationBasis: current` means the result describes current NSGs and
routes, not necessarily their state at the incident timestamp. State this
limitation for historical incidents.

## Safety

- Perform no Azure write operation or remediation.
- Do not compose arbitrary Azure CLI commands.
- Do not bypass input validation.
- Do not retry with broader permissions or another subscription unless the
  user supplies it.
- Do not expose credentials, tokens, or raw authentication output.
