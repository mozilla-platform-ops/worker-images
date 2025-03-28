Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Mercurial" {
    BeforeAll {
        $HgInfo = Get-Command "hg.exe"
        $ExpectedSoftwareVersion = [Version]($Hiera["win-worker"].hg.version)
    }
    It "Hg is installed" {
        $HgInfo.source | Should -Be "C:\Program Files\Mercurial\hg.exe"
    }
    It "Hg version matches hiera" -Skip {
        $HgInfo.FileVersionInfo.ProductVersion | Should -Be $ExpectedSoftwareVersion
    }
}
