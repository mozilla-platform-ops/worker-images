function Assert-CaptureReady {
    param([Parameter(Mandatory)][string] $Root)
    $ErrorActionPreference = 'Stop'
    $prefix = 'WimCheck' + [guid]::NewGuid().ToString('N')
    $loaded = @()
    try {
        foreach ($hive in 'SOFTWARE', 'SYSTEM') {
            $name = "$prefix$hive"
            & reg.exe load "HKLM\$name" (Join-Path $Root "Windows\System32\config\$hive") | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Cannot load offline $hive hive." }
            $loaded += $name
        }
        $software = "Registry::HKEY_LOCAL_MACHINE\${prefix}SOFTWARE"
        $system = "Registry::HKEY_LOCAL_MACHINE\${prefix}SYSTEM"
        $state = (Get-ItemProperty -LiteralPath "$software\Microsoft\Windows\CurrentVersion\Setup\State" -Name ImageState).ImageState
        if ($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw "Image is not generalized for OOBE: $state" }
        $current = (Get-ItemProperty -LiteralPath "$system\Select" -Name Current).Current
        if ($current -notin 1..999) { throw 'Offline SYSTEM hive has no valid current control set.' }
        $controlSet = 'ControlSet{0:d3}' -f [int]$current
        $start = (Get-ItemProperty -LiteralPath "$system\$controlSet\Services\WinRM" -Name Start).Start
        if ($start -ne 4) { throw 'Offline WinRM service is not disabled.' }
        $winlogon = Get-ItemProperty -LiteralPath "$software\Microsoft\Windows NT\CurrentVersion\Winlogon"
        if ($winlogon.PSObject.Properties['DefaultPassword']) { throw 'Offline autologon password remains.' }
        $policyPath = "$software\Policies\Microsoft\Windows\WinRM\Service"
        if (Test-Path -LiteralPath $policyPath) {
            $policy = Get-ItemProperty -LiteralPath $policyPath
            foreach ($name in 'AllowBasic', 'AllowUnencryptedTraffic') {
                $property = $policy.PSObject.Properties[$name]
                if ($property -and $property.Value -ne 0) { throw "Offline WinRM policy remains enabled: $name" }
            }
        }
        foreach ($path in 'bake', 'wim-bake', 'ronin\data\secrets\vault.yaml', 'Windows\Setup\Scripts\set-bake-network.ps1', 'Windows\System32\Tasks\BakeNetwork') {
            if (Test-Path -LiteralPath (Join-Path $Root $path)) { throw "Build artifact remains: $path" }
        }
        foreach ($path in 'Windows\Panther', 'Windows\System32\Sysprep') {
            $directory = Join-Path $Root $path
            if (Test-Path -LiteralPath $directory) {
                $answers = @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force |
                    Where-Object { $_.Name -in @('unattend.xml', 'autounattend.xml') })
                if ($answers.Count) { throw 'Cached answer files remain in the image.' }
            }
        }
    }
    finally {
        [array]::Reverse($loaded)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $unloadErrors = @()
        foreach ($name in $loaded) {
            & reg.exe unload "HKLM\$name" | Out-Null
            if ($LASTEXITCODE -ne 0) { $unloadErrors += "Cannot unload offline hive $name." }
        }
        if ($unloadErrors.Count) { throw ($unloadErrors -join ' ') }
    }
}
