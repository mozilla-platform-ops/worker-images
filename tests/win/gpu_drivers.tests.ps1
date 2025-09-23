Describe "Nvidia GPU Downloaded" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {

        $GPU = $null

        try {
            $GPU = $Hiera.'win-worker'.gpu.name
        } catch {}

        if (-not $GPU) {
            try {
                $GPU = $Hiera.'win-worker'.gpu.name
            } catch {}
        }

        if (-not $GPU) {
            try {
                $GPU = $Hiera.windows.gpu.name
            } catch {}
        }

        if (-not $GPU) {
            throw "GPU Drivers could not be found."
        }
    }
    It "Nvidia GPU Drivers are downloaded" {
        Test-Path "$systemdrive\Windows\Temp\$($GPU).exe" | Should -Be $true
    }
}
