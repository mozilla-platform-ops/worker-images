Describe "Nvidia GPU Downloaded" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {

        $GPU = $null

        try {
            $GPU = $Hiera.'win-worker'.'gpu-latest'.name
        } catch {}

        if (-not $GPU) {
            try {
                $GPU = $Hiera.'win-worker'.'gpu-latest'.name
            } catch {}
        }

        if (-not $GPU) {
            try {
                $GPU = $Hiera.windows.azure.'gpu-latest'.name
            } catch {}
        }

        if (-not $VGPU) {
            throw "Azure VM Agent version could not be found in any provided Hiera source."
        }
    }
    It "Nvidia GPU Drivers are downloaded" {
        Test-Path "$systemdrive\Windows\Temp\$($GPU).exe" | Should -Be $true
    }
}
