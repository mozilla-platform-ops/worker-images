Describe "Mozilla Build - Builder" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {
        $software = Get-InstalledSoftware
        $mercurial = $software | Where-Object {
            $PSItem.DisplayName -like "Mercurial*"
        }
        $mms = $software | Where-Object {
            $PSItem.DisplayName -like "Mozilla Maintenance Service*"
        }
        $pip_packages = Get-Content C:\requirements.txt
        $Install_Path = "C:\mozilla-build"

        $hg_ExpectedSoftwareVersion = $null

        try {
            $hg_ExpectedSoftwareVersion = $Hiera.'win-worker'.hg.version
        } catch {}

        if (-not $hg_ExpectedSoftwareVersion) {
            try {
                $hg_ExpectedSoftwareVersion = $Hiera.'win-worker'.variant.hg.version
            } catch {}
        }

        if (-not $hg_ExpectedSoftwareVersion) {
            try {
                $hg_ExpectedSoftwareVersion = $Hiera.windows.hg.version
            } catch {}
        }

        if (-not $hg_ExpectedSoftwareVersion) {
            throw "HG version could not be found in any provided Hiera source."
        }
                $mozillabuild_ExpectedSoftwareVersion = $null

        try {
            $mozillabuild_ExpectedSoftwareVersion = $Hiera.'win-worker'.mozilla_build.version
        } catch {}

        if (-not $mozillabuild_ExpectedSoftwareVersion) {
            try {
                $mozillabuild_ExpectedSoftwareVersion = $Hiera.'win-worker'.variant.mozilla_build.version
            } catch {}
        }

        if (-not $mozillabuild_ExpectedSoftwareVersion) {
            try {
                $mozillabuild_ExpectedSoftwareVersion = $Hiera.windows.mozilla_build.version
            } catch {}
        }

        if (-not $mozillabuild_ExpectedSoftwareVersion) {
            throw "MozillaBuild version could not be found in any provided Hiera source."
        }

        $psutil_ExpectedSoftwareVersion = $null

        try {
            $psutil_ExpectedSoftwareVersion = $Hiera.'win-worker'.mozilla_build.psutil_version
        } catch {}

        if (-not $psutil_ExpectedSoftwareVersion) {
            try {
                $psutil_ExpectedSoftwareVersion = $Hiera.'win-worker'.variant.mozilla_build.psutil_version
            } catch {}
        }

        if (-not $psutil_ExpectedSoftwareVersion) {
            try {
                $psutil_ExpectedSoftwareVersion = $Hiera.windows.mozilla_build.psutil_version
            } catch {}
        }

        if (-not $psutil_ExpectedSoftwareVersion) {
            throw "Psutil version could not be found in any provided Hiera source."
        }

        $zstandard_ExepctedSoftwareVersion = $null

        try {
            $zstandard_ExepctedSoftwareVersion = $Hiera.'win-worker'.mozilla_build.zstandard_version
        } catch {}

        if (-not $zstandard_ExepctedSoftwareVersion) {
            try {
                $zstandard_ExepctedSoftwareVersion = $Hiera.'win-worker'.variant.mozilla_build.zstandard_version
            } catch {}
        }

        if (-not $zstandard_ExepctedSoftwareVersion) {
            try {
                $zstandard_ExepctedSoftwareVersion = $Hiera.windows.mozilla_build.zstandard_version
            } catch {}
        }

        if (-not $zstandard_ExepctedSoftwareVersion) {
            throw "Zstandard version could not be found in any provided Hiera source."
        }

        $py3pip_ExpectedSoftwareVersion = $null

        try {
            $py3pip_ExpectedSoftwareVersion = $Hiera.'win-worker'.mozilla_build.py3_pip_version
        } catch {}

        if (-not $py3pip_ExpectedSoftwareVersion) {
            try {
                $py3pip_ExpectedSoftwareVersion = $Hiera.'win-worker'.variant.mozilla_build.py3_pip_version
            } catch {}
        }

        if (-not $py3pip_ExpectedSoftwareVersion) {
            try {
                $py3pip_ExpectedSoftwareVersion = $Hiera.windows.mozilla_build.py3_pip_version
            } catch {}
        }

        if (-not $py3pip_ExpectedSoftwareVersion) {
            throw "Py3 pip version could not be found in any provided Hiera source."
        }
    }
    Context "Installation" {
        It "Mozilla-Build Folder exists" {
            Test-Path "C:\mozilla-build" | Should -Be $true
        }
        It "Mozilla-Build Version" {
            Get-Content "C:\mozilla-build\VERSION" | Should -Be $mozillabuild_ExpectedSoftwareVersion
        }
        It "msys2\bin\sh.exe exists" {
            Test-Path "C:\mozilla-build\msys2\usr\bin\sh.exe" | Should -Be $true
        }
    }
    Context "Pip" {
        It "Certifi is installed" {
            $certifi = ($pip_packages | Where-Object {$psitem -Match "Certifi"}) -split "==" 
            $certifi | Should -Not -Be $null
        }
        It "PSUtil is installed" {
            $PSUtil = ($pip_packages | Where-Object {$psitem -Match "PSUtil"}) -split "==" 
            $PSUtil | Should -Not -Be $null
        }
        It "PSUtil version" {
            $PSUtil = ($pip_packages | Where-Object {$psitem -Match "PSUtil"}) -split "==" 
            $PSUtil[1] | Should -Be $psutil_ExpectedSoftwareVersion
        }
        It "ZStandard is installed" {
            $ZStandard = ($pip_packages | Where-Object {$psitem -Match "zstandard"}) -split "==" 
            $ZStandard | Should -Not -Be $null
        }
        It "ZStandard version" {
            $ZStandard = ($pip_packages | Where-Object {$psitem -Match "zstandard"}) -split "==" 
            $ZStandard[1] | Should -Be $zstandard_ExepctedSoftwareVersion
        }
        It "Python3 Pip is installed" {
            $py3pip = ($pip_packages | Where-Object {$psitem -Match "pip"}) -split "==" 
            $py3pip | Should -Not -Be $null
        }
        It "Python3 Pip version" {
            $py3pip = ($pip_packages | Where-Object {$psitem -Match "pip"}) -split "==" 
            $py3pip[1] | Should -Be $py3pip_ExpectedSoftwareVersion
        }
    }
    Context "Mercurial" -Skip {
        It "Mercurial gets installed" {
            $mercurial.DisplayName | Should -Not -Be $Null
        }
        It "Mercurial major version is the same" {
            ([Version]$mercurial.DisplayVersion ).Major | Should -Be $hg_ExpectedSoftwareVersion.Major
        }
        It "Mercurial minor version is the same" {
            ([Version]$mercurial.DisplayVersion ).Minor | Should -Be $hg_ExpectedSoftwareVersion.Minor
        }
        It "Mercurial build version is the same" {
            ([Version]$mercurial.DisplayVersion ).Build | Should -Be $hg_ExpectedSoftwareVersion.Build
        }
    }
    Context "HG Files" -Skip {
        BeforeAll {
            $hgshared_acl = (Get-Acl -Path C:\hg-shared).Access |
            Where-Object { $PSItem.IdentityReference -eq "Everyone" }
        }
        It "HG Shared folder exists" {
            Test-Path "c:\hg-Shared" | Should -Be $true
        }
        It "HG Shared folder permissions" {
            $hgshared_acl.FileSystemRights | Should -Be "FullControl"
        }
    }
    Context "Python 3 Certificate" {
        It "Certificate exists" {
            Test-Path "C:\mozilla-build\python3\Lib\site-packages\certifi\cacert.pem" | Should -Be $true
        }
    }
    Context "ToolTool" {
        It "ToolTool Cache Folder Exists" {
            Test-Path "C:\builds\tooltool_cache" | Should -Be $true
        }
        It "ToolTool Cache Folder Environment Variable" {
            $ENV:TOOLTOOL_CACHE | Should -Be "C:\builds\tooltool_cache"
        }
        It "ToolTool Cache Drive Permissions" {
            ((Get-Acl -Path "C:\builds\tooltool_cache").Access |
            Where-Object { $PSItem.IdentityReference -eq "Everyone" }).FileSystemRights |
            Should -Be "FullControl"
        }
        it "Tooltool.py exists" {
            Test-Path "C:\mozilla-build\tooltool.py" | Should -Be $true
        }
    }
    Context "Modifications" {
        It "MozMake directory exists" {
            Test-Path "C:\mozilla-build\mozmake" | Should -Be $true
        }
        It "Mozmake.exe exists" {
            Test-Path "C:\mozilla-build\mozmake\mozmake.exe" | Should -Be $true
        }
        It "Builds directory exists" {
            Test-Path "C:\builds" | Should -Be $true
        }
        It "Mozilla Build hg directory is empty" {
            Test-Path "$Install_Path\python\Scripts\hg" | Should -Be $false
        }
        It "Mozilla Build hg.exe does not exist" {
            Test-Path "$Install_Path\python\Scripts\hg.exe" | Should -Be $false
        }
        It "hg removed from mozbuild path" -Skip {
            Test-Path "$Install_Path\python3\Scripts\hg" | Should -Be $false
        }
        It "Mozillabuild environment variable" {
            $ENV:MOZILLABUILD | Should -be $Install_Path
        }
    }
    Context "Set Registry Priority" -Skip {
        BeforeEach {
            $py_key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\python.exe\PerfOptions"
            $hg_key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\hg.exe\PerfOptions"
        }
        It "Python key exists" {
            Test-Path $py_key | Should -Be $true
        }
        It "Hg key exists" {
            Test-Path $hg_key | Should -Be $true
        }
        It "CPU Priority for Python" {
            Get-ItemPropertyValue $py_key -Name "CpuPriorityClass" | Should -Be 6
        }
        It "IO Priority for Python" {
            Get-ItemPropertyValue $py_key -Name "IoPriority" | Should -Be 2
        }
        It "CPU Priority for hg" {
            Get-ItemPropertyValue $hg_key -Name "CpuPriorityClass" | Should -Be 6
        }
        It "IO Priority for hg" {
            Get-ItemPropertyValue $hg_key -Name "IoPriority" | Should -Be 2
        }
    }
    Context "Symlink Access" {
        BeforeAll {
            . "$env:windir\System32\WindowsPowerShell\v1.0\Modules\Carbon\Import-Carbon"
            $everyone = Get-Privilege -Identity "everyone"
            $system = Get-Privilege -Identity "system"
        }
        It "Everyone has symbolicprivilege" {
            $everyone | Should -Contain "SeCreateSymbolicLinkPrivilege"
        }
        It "System has symbolicprivilege" {
            $system | Should -Contain "SeCreateSymbolicLinkPrivilege"
        }
    }
    Context "Install PSUtil" {
        It "init.py path exists for python 3" {
            Test-Path "C:\mozilla-build\python3\Lib\site-packages\psutil\__init__.py" | Should -Be $true
        }
    }
    Context "Certain binaries are in msys2 path" -Skip {
        It "Tar.exe" {
            $tar = Get-Command tar
            $tar.Source | Should -Be "C:\mozilla-build\msys2\usr\bin\tar.exe"
        }
        It "Find.exe" {
            $bash = Get-Command find
            $bash.Source | Should -Be "C:\mozilla-build\msys2\usr\bin\find.exe"
        }
    }
}
