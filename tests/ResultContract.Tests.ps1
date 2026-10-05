$modulePath = Join-Path $PSScriptRoot '..\scripts\modules\ResultContract.psm1'
Import-Module $modulePath -Force

Describe 'Tool result contract' {
    It 'emits the versioned JSON envelope' {
        $result = New-ToolResult `
            -Tool 'example-tool' `
            -Status no-finding `
            -Summary 'No relevant evidence was found.' `
            -Confidence medium `
            -DurationMs 10

        $json = $result | Write-ToolResult | ConvertFrom-Json

        $json.schemaVersion | Should Be '1.0'
        $json.tool | Should Be 'example-tool'
        $json.status | Should Be 'no-finding'
        @($json.evidence).Count | Should Be 0
    }
}
