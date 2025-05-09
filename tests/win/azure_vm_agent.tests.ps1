Describe "Windows Azure VM Agent" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera

        Write-Host "`n[DEBUG] Combined Hiera structure (truncated):"
        $Hiera | ConvertTo-Json -Depth 5 | Write-Host
    }

    BeforeAll {
        $Software = Get-InstalledSoftware | Where-Object {
            $_.DisplayName -like "Windows Azure VM Agent*"
        }

        $VmAgentVersionRaw = $null

        # Safely attempt each fallback level
        try {
            $VmAgentVersionRaw = $Hiera.'win-worker'.azure.vm_agent.version
        } catch {}

        if (-not $VmAgentVersionRaw) {
            try {
                $VmAgentVersionRaw = $Hiera.'win-worker'.variant.azure.vm_agent.version
            } catch {}
        }

        if (-not $VmAgentVersionRaw) {
            try {
                $VmAgentVersionRaw = $Hiera.windows.azure.vm_agent.version
            } catch {}
        }

        if (-not $VmAgentVersionRaw) {
            throw "Azure VM Agent version could not be found in any provided Hiera source."
        }

        Write-Host "✅ Resolved VM Agent version: $VmAgentVersionRaw"

        $ExpectedSoftwareVersion = [Version]($VmAgentVersionRaw -split "_")[0]
    }

    It "Windows Azure VM Agent is installed" {
        $Software.DisplayName | Should -Not -Be $null
    }

    It "Windows Azure VM Agent major version" {
        ([Version]$Software.DisplayVersion).Major | Should -Be $ExpectedSoftwareVersion.Major
    }

    It "Windows Azure VM Agent minor version" {
        ([Version]$Software.DisplayVersion).Minor | Should -Be $ExpectedSoftwareVersion.Minor
    }

    It "Windows Azure VM Agent build version" {
        ([Version]$Software.DisplayVersion).Build | Should -Be $ExpectedSoftwareVersion.Build
    }

    It "Windows Azure VM Agent revision" {
        ([Version]$Software.DisplayVersion).Revision | Should -Be $ExpectedSoftwareVersion.Revision
    }
}
