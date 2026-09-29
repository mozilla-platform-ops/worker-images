# For images using Ronin's hardened package staging directory.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Hiera', Justification = 'Pester consumes Hiera in BeforeAll.')]
param([hashtable]$Hiera)

Describe "Nvidia GPU Drivers Downloaded" {
    BeforeAll {
        $GPU = $Hiera.windows.gpu.name
    }
    It "Nvidia GPU Drivers are downloaded to RoninPackages" {
        $GPU | Should -Not -BeNullOrEmpty
        Test-Path "$env:SystemDrive\RoninPackages\$($GPU).exe" -PathType Leaf | Should -Be $true
    }
}
