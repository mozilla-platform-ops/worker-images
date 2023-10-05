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

<#     ## Import Pester module explicitly
    Import-Module -Name Pester -Force -PassThru

    [PesterConfiguration].Assembly #>

    Get-Module Pester -ListAvailable

    Import-Module -Name Pester -Force -PassThru

    ## Set path to role yaml
    $RolePath = "C:\ronin\data\roles\$Role.yaml"

    if (-Not (Test-Path $RolePath)) {
        Write-Host "Unable to find $rolePath"
        Exit 1
    }

    ## Output what we're working with
    Write-host "Processing Role: $Role"
    Write-host "Processing Config: $Config"
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
    Write-host ("Processing tests: {0}" -f $tests.fullname)
    Write-Log -message ('{0} :: Processing tests: {1}' -f $($MyInvocation.MyCommand.Name), $tests.fullname) -severity 'DEBUG'
    ## Try changing into the directory and running tests there
    Set-Location "C:/Tests"
    ## Build the container and pass in the hiera key, and pass in just the test names, not the full path(s)
    $Container = New-PesterContainer -Path $tests.Name -Data @{
        File = $RolePath
    }
    $config = New-PesterConfiguration -Hashtable @{
        Run = @{
            Container = $Container
        }
        TestResult = {
            Enabled = $true
        }
        Output = {
            Verbosity = "Detailed"
        }
    }
    #$config.Run.Container = $Container
    #$config.Filter.Tag = $Tags
    #$config.TestResult.Enabled = $true
    #$config.Output.Verbosity = "Detailed"
    #if ($ExcludeTag) {
    #    $config.Filter.ExcludeTag = $ExcludeTag
    #}
    #if ($PassThru) {
    #    $config.Run.Passthru = $true
    #}
    Invoke-Pester -Configuration $config
}