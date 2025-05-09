Describe "Windows Azure VM Agent" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
        $WindowsHira = $Data.WindowsHiera
    }

    BeforeAll {
        $Software = Get-InstalledSoftware | Where-Object {
            $_.DisplayName -like "Windows Azure VM Agent*"
        }

        $VmAgentVersionRaw = $null

        if ($Hiera.'win-worker'.azure.vm_agent.version) {
            $VmAgentVersionRaw = $Hiera.'win-worker'.azure.vm_agent.version
        } elseif ($Hiera.'win-worker'.variant.azure.vm_agent.version) {
            $VmAgentVersionRaw = $Hiera.'win-worker'.variant.azure.vm_agent.version
        } elseif ($WindowsHira.azure.vm_agent.version) {
            $VmAgentVersionRaw = $WindowsHira.azure.vm_agent.version
        }

        if (-not $VmAgentVersionRaw) {
            throw "Azure VM Agent version could not be found in any provided Hiera source."
        }

        $ExpectedSoftwareVersion = [Version]($VmAgentVersionRaw -split "_")[0]
    }

    It "Windows Azure VM Agent is installed" {
        $Software.DisplayName | Should -Not -Be $Null
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
