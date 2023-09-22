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
    ## Grab the tests from hiera
    $Hiera = Convertfrom-Yaml (Get-Content -Path "C:\ronin\data\roles\$Role.yaml" -Raw)
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
    ## Build the container and pass in the hiera key
    $Container = New-PesterContainer -Path $tests.FullName -Data @{
        File = "C:\ronin\data\roles\$Role.yaml"
    }
    $config = New-PesterConfiguration
    $config.Run.Container = $Container
    #$config.Filter.Tag = $Tags
    $config.TestResult.Enabled = $true
    $config.Output.Verbosity = "Detailed"
    #if ($ExcludeTag) {
    #    $config.Filter.ExcludeTag = $ExcludeTag
    #}
    if ($PassThru) {
        $config.Run.Passthru = $true
    }
    Invoke-Pester -Configuration $config
}