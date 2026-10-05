$modulePath = Join-Path $PSScriptRoot '..\scripts\modules\NsgEvaluation.psm1'
Import-Module $modulePath -Force

Describe 'Get-NsgRuleDecision' {
    BeforeAll {
        $fixturePath = Join-Path $PSScriptRoot 'fixtures\nsg\rules.json'
        $rules = @(Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json)
        $sourceAddress = [Net.IPAddress]::Parse('10.20.1.4')
        $destinationAddress = [Net.IPAddress]::Parse('192.168.40.10')
    }

    It 'matches the explicit HTTPS allow rule' {
        $decision = Get-NsgRuleDecision `
            -Rules $rules `
            -Direction Outbound `
            -SourceAddress $sourceAddress `
            -DestinationAddress $destinationAddress `
            -Protocol Tcp `
            -DestinationPort 443

        $decision.status | Should Be 'matched'
        $decision.access | Should Be 'Allow'
        $decision.rule.name | Should Be 'Allow-OnPrem-Https'
    }

    It 'falls through to the default deny rule for a different port' {
        $decision = Get-NsgRuleDecision `
            -Rules $rules `
            -Direction Outbound `
            -SourceAddress $sourceAddress `
            -DestinationAddress $destinationAddress `
            -Protocol Tcp `
            -DestinationPort 22

        $decision.status | Should Be 'matched'
        $decision.access | Should Be 'Deny'
        $decision.rule.name | Should Be 'Deny-All-Outbound'
    }

    It 'marks an unresolved higher-priority service tag as inconclusive' {
        $rulesWithTag = @(
            [pscustomobject] @{
                name = 'Service-Tag-Rule'
                priority = 50
                direction = 'Outbound'
                access = 'Deny'
                protocol = 'Tcp'
                sourceAddressPrefix = 'VirtualNetwork'
                sourcePortRange = '*'
                destinationAddressPrefix = '192.168.40.0/24'
                destinationPortRange = '443'
            }
        ) + $rules

        $decision = Get-NsgRuleDecision `
            -Rules $rulesWithTag `
            -Direction Outbound `
            -SourceAddress $sourceAddress `
            -DestinationAddress $destinationAddress `
            -Protocol Tcp `
            -DestinationPort 443

        $decision.status | Should Be 'inconclusive'
        $decision.rule.name | Should Be 'Service-Tag-Rule'
    }

    It 'resolves the VirtualNetwork service tag from discovered topology prefixes' {
        $virtualNetworkRule = @(
            [pscustomobject] @{
                name = 'AllowVnetOutBound'
                priority = 65000
                direction = 'Outbound'
                access = 'Allow'
                protocol = '*'
                sourceAddressPrefix = 'VirtualNetwork'
                sourcePortRange = '0-65535'
                destinationAddressPrefix = 'VirtualNetwork'
                destinationPortRange = '*'
            }
        )

        $decision = Get-NsgRuleDecision `
            -Rules $virtualNetworkRule `
            -Direction Outbound `
            -SourceAddress ([Net.IPAddress]::Parse('10.0.1.4')) `
            -DestinationAddress ([Net.IPAddress]::Parse('10.0.1.6')) `
            -Protocol Tcp `
            -DestinationPort 22 `
            -VirtualNetworkPrefixes @('10.0.0.0/16')

        $decision.status | Should Be 'matched'
        $decision.access | Should Be 'Allow'
    }
}

Describe 'Test-IpInCidr' {
    It 'matches an IPv4 address inside a prefix' {
        Test-IpInCidr -Address ([Net.IPAddress]::Parse('10.20.1.4')) -Cidr '10.20.1.0/24' | Should Be $true
    }

    It 'rejects an IPv4 address outside a prefix' {
        Test-IpInCidr -Address ([Net.IPAddress]::Parse('10.20.2.4')) -Cidr '10.20.1.0/24' | Should Be $false
    }
}
