Function Invoke-RoninTest {
    [CmdletBinding()]
    param (
        [String] $Role,
        [String] $Config,
        [Switch] $PassThru
    )

    $RolePath = "C:\ronin\data\roles\$Role.yaml"
    $WinPath = "C:\ronin\data\os\Windows.yaml"
    $ConfigPath = "C:\Config\$Config.yaml"

    if (-not (Test-Path $RolePath)) { Write-Host "Unable to find $RolePath"; exit 1 }
    if (-not (Test-Path $WinPath)) { Write-Host "Unable to find $WinPath"; exit 1 }
    if (-not (Test-Path $ConfigPath)) { Write-Host "Unable to find config: $ConfigPath"; exit 1 }

    $Hiera = ConvertFrom-Yaml (Get-Content -Path $RolePath -Raw)
    $WindowsHiera = ConvertFrom-Yaml (Get-Content -Path $WinPath -Raw)
    $Config_tests = ConvertFrom-Yaml (Get-Content -Path $ConfigPath -Raw)

    if ($null -eq $Hiera) { Write-Host "Parsed Role Hiera is null."; exit 1 }
    if ($null -eq $Config_tests -or -not $Config_tests.tests) {
        Write-Host "No tests found in $ConfigPath"
        exit 1
    }

    Function Merge-HashTables {
        param (
            [hashtable]$Base,
            [hashtable]$Overlay
        )
        $Result = @{}

        foreach ($key in $Base.Keys) {
            if ($Base[$key] -is [hashtable] -and $Overlay.ContainsKey($key) -and $Overlay[$key] -is [hashtable]) {
                $Result[$key] = Merge-HashTables -Base $Base[$key] -Overlay $Overlay[$key]
            } else {
                $Result[$key] = $Base[$key]
            }
        }

        foreach ($key in $Overlay.Keys) {
            if (-not $Result.ContainsKey($key)) {
                $Result[$key] = $Overlay[$key]
            }
        }

        return $Result
    }

    $CombinedHiera = Merge-HashTables -Base $WindowsHiera -Overlay $Hiera

    $tests = foreach ($t in $Config_tests.tests) {
        Get-ChildItem -Path "C:/Tests/$t"
    }

    if ($null -eq $tests -or $tests.FullName -contains $null) {
        Write-Host "One or more test files could not be found."
        exit 1
    }

    ## DEBUG
    Write-Debug "Combined Hiera:`n$(ConvertTo-Yaml $CombinedHiera)"

    $Container = New-PesterContainer -Path $tests.FullName -Data @{ Hiera = $CombinedHiera }
    $Configuration = New-PesterConfiguration
    $Configuration.Run.Exit = $true
    $Configuration.Run.Container = $Container
    $Configuration.TestResult.Enabled = $true
    $Configuration.Output.Verbosity = "Detailed"

    Invoke-Pester -Configuration $Configuration
}
