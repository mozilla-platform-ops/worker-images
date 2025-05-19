Describe "Git" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {
        $Git = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -match "Git"
        }
        $ExpectedSoftwareVersion = $null

        try {
            $ExpectedSoftwareVersion = $Hiera.'win-worker'.git.version
        } catch {}

        if (-not $ExpectedSoftwareVersion) {
            try {
                ExpectedSoftwareVersion = $Hiera.'win-worker'.variant.git.version
            } catch {}
        }

        if (-not $ExpectedSoftwareVersion) {
            try {
                $ExpectedSoftwareVersion = $Hiera.windows.git.version
            } catch {}
        }

        if (-not $ExpectedSoftwareVersion) {
            throw "HG version could not be found in any provided Hiera source."
        }        
    }
    It "Git is installed" {
        $Git.DisplayName | Should -Not -Be $null
    }

    It "Git Version is the same" {
        $Git.DisplayVersion | Should -Be $ExpectedSoftwareVersion
    }
}
