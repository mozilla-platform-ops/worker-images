Describe "Common Tools" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {
        $gpg4win = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -like "Gpg4win (2.3.0)"
        }
        $7zip = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -match "Zip"
        }
        $sublimetext = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -match "Sublime Text*"
        }
    }
    Context "Process Monitor is present" {
        It "Folder is present" {
            Test-Path "C:\ProcessMonitor" | Should -Be $true
        }
        It "Binary is present" {
            Test-Path "C:\ProcessMonitor\Procmon.exe" | Should -Be $true
        }
        It "Version is 3.50" {
            ((Get-Item "C:\ProcessMonitor\Procmon.exe").versioninfo).fileversion | Should -Be 3.50
        }
    }
    Context "Process Explorer is present" {
        It "Folder is present" {
            Test-Path "C:\ProcessExplorer" | Should -Be $true
        }
        It "Binary is present" {
            Test-Path "C:\ProcessExplorer\procexp.exe" | Should -Be $true
        }
        It "Version is 16.21" {
            ((Get-Item "C:\ProcessExplorer\procexp.exe").versioninfo).fileversion | Should -Be 16.21
        }
    }
    Context "7-Zip" {
        It "7-Zip is installed" {
            $7zip.DisplayName | Should -Not -Be $null
        }

        It "7-Zip Version is 18.06.00.0" {
            $7zip.DisplayVersion | Should -Be "18.06.00.0"
        }
    }
    Context "Sublime Text" {
        It "Sublime Text is installed" {
            $sublimetext.DisplayName | Should -Not -Be $null
        }
        It "Binary exists" {
            Test-Path "$ENV:ProgramFiles\Sublime Text 3\subl.exe" | Should -BeTrue
        }
    }

}
