$modulePath = Join-Path $PSScriptRoot '..\scripts\modules'

Describe 'Entry-point module loading' {
    AfterEach {
        @(
            'PathEvaluation',
            'NsgEvaluation',
            'AzureMaintenance',
            'AzureNetwork',
            'AzureCli'
        ) | ForEach-Object {
            Remove-Module $_ -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves Azure CLI commands after loading the maintenance adapter' {
        Import-Module (Join-Path $modulePath 'AzureCli.psm1') -Force
        Import-Module (Join-Path $modulePath 'AzureMaintenance.psm1') -Force

        (Get-Command Assert-AzureCliAuthenticated -ErrorAction SilentlyContinue).Name |
            Should Be 'Assert-AzureCliAuthenticated'
        (Get-Command Get-AzureSubscriptionIds -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-AzureSubscriptionIds'
    }

    It 'preserves Azure CLI commands after loading the network adapter' {
        Import-Module (Join-Path $modulePath 'AzureCli.psm1') -Force
        Import-Module (Join-Path $modulePath 'AzureNetwork.psm1') -Force

        (Get-Command Assert-AzureCliAuthenticated -ErrorAction SilentlyContinue).Name |
            Should Be 'Assert-AzureCliAuthenticated'
        (Get-Command Get-AzureSubscriptionIds -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-AzureSubscriptionIds'
        (Get-Command Find-AzureNetworkInterfaceByPrivateIp -ErrorAction SilentlyContinue).Name |
            Should Be 'Find-AzureNetworkInterfaceByPrivateIp'
        (Get-Command Get-NetworkTopology -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-NetworkTopology'
        (Get-Command Get-EffectiveNsgRules -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-EffectiveNsgRules'
        (Get-Command Get-EffectiveRoutes -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-EffectiveRoutes'
    }

    It 'preserves network and evaluation commands after the complete entry-point sequence' {
        Import-Module (Join-Path $modulePath 'AzureCli.psm1') -Force
        Import-Module (Join-Path $modulePath 'AzureNetwork.psm1') -Force
        Import-Module (Join-Path $modulePath 'NsgEvaluation.psm1') -Force
        Import-Module (Join-Path $modulePath 'PathEvaluation.psm1') -Force

        (Get-Command Get-NetworkTopology -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-NetworkTopology'
        (Get-Command Get-NsgRuleDecision -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-NsgRuleDecision'
        (Get-Command Get-RouteDecision -ErrorAction SilentlyContinue).Name |
            Should Be 'Get-RouteDecision'
    }
}
