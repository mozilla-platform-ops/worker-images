Function Invoke-RoninTest {
    [CmdletBinding()]
    param (
        [String]
        $Role,

        [String]
        $Config,

        [Switch]
        $PassThru
    )

    # Read and parse the role and Windows Hiera files
    $RolePath = "C:\ronin\data\roles\$Role.yaml"
    $WinPath = "C:\ronin\data\os\Windows.yaml"

    if (-not (Test-Path $RolePath)) {
        Write-Host "Unable to find $RolePath"
        exit 1
    }
    if (-not (Test-Path $WinPath)) {
        Write-Host "Unable to find $WinPath"
        exit 1
    }

    $Hiera = ConvertFrom-Yaml (Get-Content -Path $RolePath -Raw)
    $WindowsHiera = ConvertFrom-Yaml (Get-Content -Path $WinPath -Raw)

    $ConfigPath = "C:\Config\$Config.yaml"
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Unable to find config: $ConfigPath"
        exit 1
    }

    $Config_tests = ConvertFrom-Yaml (Get-Content -Path $ConfigPath -Raw)

    if ($null -eq $Hiera) {
        Write-Host "Parsed Hiera data from role is null."
        exit 1
    }

    if ($null -eq $Config_tests -or -not $Config_tests.tests) {
        Write-Host "No tests found in $ConfigPath"
        exit 1
    }

    # Load test files
    $tests = foreach ($t in $Config_tests.tests) {
        Get-ChildItem -Path "C:/Tests/$t"
    }

    if ($null -eq $tests -or $tests.FullName -contains $null) {
        Write-Host "One or more test files could not be found."
        exit 1
    }

    foreach ($thing in $tests.FullName) {
        Write-Host ("Processing tests: {0}" -f $thing)
    }

    # Combine the parsed YAML data into a single hashtable
    $PesterData = @{
        Hiera = $Hiera
        WindowsHiera = $WindowsHiera
    }

    # Build and run Pester
    $Container = New-PesterContainer -Path $tests.FullName -Data $PesterData
    $Configuration = New-PesterConfiguration
    $Configuration.Run.Exit = $true
    $Configuration.Run.Container = $Container
    $Configuration.TestResult.Enabled = $true
    $Configuration.Output.Verbosity = "Detailed"
    Invoke-Pester -Configuration $Configuration
}
