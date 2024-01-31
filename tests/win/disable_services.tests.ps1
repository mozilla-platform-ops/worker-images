Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Disable Services" {
    Context "<_> service" -ForEach @(
        "wsearch",
        "puppet"
    ) {
        It "Exists as a service" {
            Get-Service $_ | Should -Not -Be $null
        }
        It "Windows Search is disabled" {
            (Get-Service $_).Status | Should -Be "Stopped"
        }
    }
    Context "Windows Update" {
        BeforeAll {
            $win_update_key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            $win_au_key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            $win_update_preview_builds = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds"
            $service = "wuauserv"
            $service_key = "HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv"
        }

        It "Exists as a service" {
            Get-Service $service | Should -Not -Be $null
        }
        It "Windows Update is disabled" {
            (Get-Service $service).Status | Should -Be "Stopped"
        }
        It "Windows Update SearchOrderConfig is 0" {
            Get-ItemPropertyValue HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching -Name "SearchOrderConfig" | Should -Be 0
        }
        It "Windows Update AUOptions is 1" {
            Get-ItemPropertyValue $win_au_key -Name "AUOptions" | Should -Be 1
        }
        It "Windows Update NoAutoUpdate is 1" {
            Get-ItemPropertyValue $win_au_key -Name "NoAutoUpdate" | Should -Be 1
        }
        It "wuauserv start set to disable" {
            Get-ItemPropertyValue $service_key -Name "Start" | Should -Be 4
        }
    }
    Context "Disable User Account Control" {
        It "UAC is enabled" {
            Get-ItemPropertyValue HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name "EnableLUA" | Should -Be 1
        }
    }
    Context "Disable Local Clipboard" -Tags "Azure" -Skip {
        It "Service is stopped" {
            (Get-Service -Name "cbdhsvc_*").Status | Should -Be "Stopped"
        }
        It "<_> is set to disabled" -Foreach @(
            (Get-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\cbdhsvc_*").PSChildName
        ){
            Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Services\$_" -Name "Start" | Should -Be 4
        }
    }
}
