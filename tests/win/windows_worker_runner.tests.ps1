Describe "Taskcluster" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {

        $variant = $Hiera.'win-worker'.variant
        $win = $Hiera.windows

        $nssm = if ($variant.nssm.version) { $variant.nssm.version } else { $win.nssm.version }
        $taskcluster_ExpectedSoftwareVersion = if ($variant.taskcluster.version) { $variant.taskcluster.version } else { $win.taskcluster.version }

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
        It "Generic Worker matches the configured build" {
            $sourceBuild = $win.taskcluster.'generic-worker'.source_build
            if ($sourceBuild) {
                $receipt = Get-Content 'C:\generic-worker\generic-worker.exe.source-build.json' -Raw | ConvertFrom-Json
                $receipt.repository | Should -BeExactly $sourceBuild.repository
                $receipt.revision | Should -BeExactly $sourceBuild.revision
                $receipt.go_version | Should -BeExactly $sourceBuild.go_version
                $receipt.binary_hash | Should -Be (Get-FileHash 'C:\generic-worker\generic-worker.exe' -Algorithm SHA256).Hash
                return
            }
            Start-Process -FilePath "C:\generic-worker\generic-worker.exe" -ArgumentList "--short-version" -RedirectStandardOutput "Testdrive:\gwversion.txt" -Wait -NoNewWindow
            Get-Content "Testdrive:\gwversion.txt" | Should -be $taskcluster_ExpectedSoftwareVersion
        }
    }
    Context "Worker Runner" {
        It "Worker Runner exists" {
            Test-Path "C:\worker-runner\start-worker.exe" | Should -Be $true
        }
        It "Worker Runner Version is correct" {
            $sourceBuild = $win.taskcluster.'generic-worker'.source_build
            if ($sourceBuild) {
                $receipt = Get-Content 'C:\generic-worker\generic-worker.exe.source-build.json' -Raw | ConvertFrom-Json
                if ($receipt.runner_hash) {
                    $receipt.revision | Should -BeExactly $sourceBuild.revision
                    $receipt.runner_hash | Should -Be (Get-FileHash 'C:\worker-runner\start-worker.exe' -Algorithm SHA256).Hash
                    return
                }
            }
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
