Describe "Taskcluster" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {

        $nssm = ($Hiera.'win-worker'.nssm.version)
        $nssm = $null

        try {
            $nssm = $Hiera.'win-worker'.nssm.version
        } catch {}

        if (-not $nssm) {
            try {
                $nssm = $Hiera.'win-worker'.variant.nssm.version
            } catch {}
        }

        if (-not $nssm) {
            try {
                $nssm = $Hiera.windows.taskcluster.nssm.version
            } catch {}
        }

        if (-not $nssm) {
            throw "NSSM version could not be found in any provided Hiera source."
        }

        $taskcluster_ExpectedSoftwareVersion = $null

        try {
            $taskcluster_ExpectedSoftwareVersion = $Hiera.'win-worker'.generic_worker.version
        } catch {}

        if (-not $taskcluster_ExpectedSoftwareVersion) {
            try {
                $taskcluster_ExpectedSoftwareVersion = $Hiera.'win-worker'.variant.taskcluster.version
            } catch {}
        }

        if (-not $taskcluster_ExpectedSoftwareVersion) {
            try {
                $taskcluster_ExpectedSoftwareVersion = $Hiera.windows.taskcluster.version
            } catch {}
        }

        if (-not $taskcluster_ExpectedSoftwareVersion) {
            throw "HG version could not be found in any provided Hiera source."
        }

    }
    Context "Non-Sucking Service Manager" {
        It "NSSM is installed" {
            Test-Path "C:\nssm\nssm-$($nssm)\win64\nssm.exe" | Should -Be $true
        }
        It "NSSM Windows Service Exists" {
            Get-Service "worker-runner" | Should -Not -Be $null
        }
    }
    Context "Taskcluster directories" {
        It "Generic Worker" {
            Test-Path "C:\generic-worker" | Should -Be $true
        }
        It "Worker Runner" {
            Test-Path "C:\worker-runner" | Should -Be $true
        }
    }
    Context "Generic Worker" {
        It "Generic Worker exists" {
            Test-Path "C:\generic-worker\generic-worker.exe" | Should -Be $true
        }
        It "Generic Worker Version is correct" {
            Start-Process -FilePath "C:\generic-worker\generic-worker.exe" -ArgumentList "--short-version" -RedirectStandardOutput "Testdrive:\gwversion.txt" -Wait -NoNewWindow
            Get-Content "Testdrive:\gwversion.txt" | Should -be $taskcluster_ExpectedSoftwareVersion
        }
    }
    Context "Worker Runner" {
        It "Worker Runner exists" {
            Test-Path "C:\worker-runner\start-worker.exe" | Should -Be $true
        }
        It "Worker Runner Version is correct" {
            Start-Process -FilePath "C:\worker-runner\start-worker.exe" -ArgumentList "--short-version" -RedirectStandardOutput "Testdrive:\startworkerversion.txt" -Wait -NoNewWindow
            Get-Content "Testdrive:\startworkerversion.txt" | Should -be $taskcluster_ExpectedSoftwareVersion
        }
    }
    Context "Proxy" {
        It "Proxy exists" {
            Test-Path "C:\generic-worker\taskcluster-proxy.exe" | Should -Be $true
        }
        It "Proxy version is correct" {
            Start-Process -FilePath "C:\generic-worker\taskcluster-proxy.exe" -ArgumentList "--short-version" -RedirectStandardOutput "Testdrive:\proxyversion.txt" -Wait -NoNewWindow
            Get-Content "Testdrive:\proxyversion.txt" | Should -be $taskcluster_ExpectedSoftwareVersion
        }
    }
    Context "Livelog" {
        It "Livelog exists" {
            Test-Path "C:\generic-worker\livelog.exe" | Should -Be $true
        }
        It "Livelog version is correct" {
            Start-Process -FilePath "C:\generic-worker\livelog.exe" -ArgumentList "--short-version" -RedirectStandardOutput "Testdrive:\livelogversion.txt" -Wait -NoNewWindow
            Get-Content "Testdrive:\livelogversion.txt" | Should -be $taskcluster_ExpectedSoftwareVersion
        }
    }
}
