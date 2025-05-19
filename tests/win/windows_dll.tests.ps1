Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Taskcluster" {
    Context "IAccessible2 DLL is loaded" {
        It "DLL Path exists" {
            Test-Path "C:\ProgramData\PuppetLabs\ronin\IAccessible2proxy.dll" | Should -Be $true
        }
        It "NSSM Windows Service Exists" {
            Get-ChildItem -Path Registry::HKEY_CLASSES_ROOT\CLSID -Recurse -ErrorAction SilentlyContinue | Where-Object {
            (Get-ItemProperty -Path $_.PSPath -ErrorAction Stop)."(default)" -eq "C:\ProgramData\PuppetLabs\ronin\IAccessible2proxy.dll"
        } | Should -Not -Be $null
        }
    }
}
