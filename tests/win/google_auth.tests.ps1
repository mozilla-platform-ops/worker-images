Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
    $Directories = Get-WinFactsDirectories
}

Describe "Google Auth" {
    It "Google Folder Exists" {
        Test-Path "$($Directories.custom_win_programdata)\Google" | Should -Be $True
    }
    It "Google Auth Folder" {
        Test-Path "$($Directories.custom_win_programdata)\Google\Auth" | Should -Be $True
    }
}
