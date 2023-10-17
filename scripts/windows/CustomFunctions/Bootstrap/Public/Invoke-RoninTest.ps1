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

    ## Set path to role yaml
    $RolePath = "C:\ronin\data\roles\$Role.yaml"

    if (-Not (Test-Path $RolePath)) {
        Write-Host "Unable to find $rolePath"
        Exit 1
    }

    ## Output what we're working with
    Write-host "Processing Role: $Role"
    Write-host "Processing Config: $Config"

    Write-Log -message ('{0} :: Processing Role: {1}' -f $($MyInvocation.MyCommand.Name), $Role) -severity 'DEBUG'
    Write-Log -message ('{0} :: Processing Config: {1}' -f $($MyInvocation.MyCommand.Name), $Config) -severity 'DEBUG'
    Write-Log -message ('{0} :: Processing RolePath: {1}' -f $($MyInvocation.MyCommand.Name), $RolePath) -severity 'DEBUG'

    ## Grab the tests from hiera
    $Hiera = Convertfrom-Yaml (Get-Content -Path $RolePath -Raw)
    $Config_tests = Convertfrom-Yaml (Get-Content -Path "C:\Config\$Config.yaml" -Raw)
    if ($null -eq $Hiera) {
        Write-host "Unable to find hiera key lookup $Role"
        exit 1
    }
    if ($null -eq $Config_tests) {
        Write-host "Unable to find hiera key lookup $Config"
        exit 1
    }
    ## Select the tests and pass through to pester
    $tests = foreach ($t in $Config_tests.tests) {
        Get-ChildItem -Path "C:/Tests/$t"
    }
    ## Check the output of $tests to make sure the contents are there
    if ($null -eq $tests) {
        Write-host "Unable to select tests based on $config lookup"
        exit 1
    }
    ## Output the Fullname paths
    Foreach ($thing in $tests.fullname) {
        Write-host ("Processing tests: {0}" -f $thing)
        Write-Log -message ('{0} :: Processing tests: {1}' -f $($MyInvocation.MyCommand.Name), $thing) -severity 'DEBUG'
    }
    ## Build the container and pass in the hiera key, and pass in just the test names, not the full path(s)
    $Container = New-PesterContainer -Path $tests.FullName -Data @{
        File = $RolePath
    }
    $Configuration = New-PesterConfiguration
    $Configuration.Run.Container = $Container
    $Configuration.TestResult.Enabled = $true
    $Configuration.Output.Verbosity = "Detailed"
    Invoke-Pester -Configuration $Configuration
}