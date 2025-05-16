Describe "Mercurial" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {
        $HgInfo = Get-Command "hg.exe"
        $ExpectedSoftwareVersion = $null

        try {
            $ExpectedSoftwareVersion = $Hiera.'win-worker'.hg.version
        } catch {}

        if (-not $ExpectedSoftwareVersion) {
            try {
                ExpectedSoftwareVersion = $Hiera.'win-worker'.variant.hg.version
            } catch {}
        }

        if (-not $ExpectedSoftwareVersion) {
            try {
                $ExpectedSoftwareVersion = $Hiera.windows.hg.version
            } catch {}
        }

        if (-not $ExpectedSoftwareVersion) {
            throw "HG version could not be found in any provided Hiera source."
        }

    }

    It "Hg is installed" {
        $HgInfo.source | Should -Be "C:\Program Files\Mercurial\hg.exe"
    }
    It "Hg version matches hiera" -Skip {
        $HgInfo.FileVersionInfo.ProductVersion | Should -Be $ExpectedSoftwareVersion
    }
}
