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
    ## Select the tests and pass through to pester
    $tests = @($Hiera.Tests) | ForEach-Object {
        $name = $psitem
        Get-ChildItem -Path "C:/Tests/$name"
    }
    ## Build the container and pass in the hiera key
    $Container = New-PesterContainer -Path $tests -Data @{
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