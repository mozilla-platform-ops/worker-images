Function Invoke-RoninTest {
    [CmdletBinding()]
    param (
        [String]
        $Key = $ENV:base_image,

        [Switch]
        $PassThru
    )
    ## Grab the tests from hiera
    $Hiera = Convertfrom-Yaml (Get-Content -Path "C:\ronin\data\roles\$key.yaml" -Raw)
    if ($null -eq $Hiera) {
        Write-host "Unable to find hiera key lookup $key"
        exit 1
    }
    ## Select the tests and pass through to pester
    $tests = foreach ($t in $Hiera.tests) {
        Get-ChildItem -Path "C:/Tests/$name"
    }

    ## Check the output of $tests to make sure the contents are there
    if ($null -eq $tests) {
        Write-host "Unable to select tests based on hiera lookup"
        exit 1
    }
    else {
        foreach ($thing in $tests) {
            Write-host "Processing $($thing.fullname)"
        }
    }
    ## Build the container and pass in the hiera key
    $Container = New-PesterContainer -Path $tests.FullName -Data @{
        File = "C:\ronin\data\roles\$Key.yaml"
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