Describe "Erorr reporting" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    It "Error dump folder exists" -Skip {
        Test-Path "D:\error-dumps" | Should -Be $True
    }
    It "Error dumpfolder registry exists" -Skip {
        Get-ItemPropertyValue "HKLM:\Software\Microsoft\Windows\Windows\Error\Reporting" -Name "DumpFolder" -ErrorAction SilentlyContinue | Should -Be "D:\error-dumps"
    }
    It "Error localdumps registry exists" {
        Get-ItemPropertyValue "HKLM:\Software\Microsoft\Windows\Windows\Error\Reporting" -Name "LocalDumps" -ErrorAction SilentlyContinue | Should -Be 1
    }
    It "Error DontShowUI registry exists" {
        Get-ItemPropertyValue "HKLM:\Software\Microsoft\Windows\Windows\Error\Reporting" -Name "DontShowUI" -ErrorAction SilentlyContinue | Should -Be 1
    }
}
